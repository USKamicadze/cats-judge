use v5.10;
use strict;
use warnings;

use IO::Uncompress::Unzip qw(unzip $UnzipError);
use File::Copy qw(copy);
use File::Fetch;
use File::Path qw(make_path);
use File::Spec;
use Getopt::Long;
use IPC::Cmd;
use List::Util qw(max);

use lib 'lib';
use CATS::ConsoleColor qw(colored);
use CATS::DevEnv::Detector::Utils qw(globq run);
use CATS::FileUtil;
use CATS::Loggers;
use CATS::Spawner::Platform;

$| = 1;

sub usage
{
    my (undef, undef, $cmd) = File::Spec->splitpath($0);
    print <<"USAGE";
Usage:
    $cmd
    $cmd --step <num> ...
        [--bin <spawner bin mode: download[:version[:remote-repository]]|build>]
        [--devenv <devenv-filter>] [--modules <modules-filter>]
        [--verbose] [--force]
    $cmd --help|-?
USAGE
    exit;
}

GetOptions(
    \my %opts,
    'step=i@',
    'bin=s',
    'devenv=s',
    'modules=s',
    'verbose',
    'force',
    'help|?',
) or usage;
usage if defined $opts{help};

CATS::DevEnv::Detector::Utils::set_debug(1, *STDERR) if $opts{verbose};

printf "Installing cats-judge%s\n", ($opts{verbose} ? ' verbosely' : '');

my %filter_steps;
if ($opts{step}) {
    my @steps = @{$opts{step}};
    undef @filter_steps{@steps};
    printf "Will only run steps: %s\n", join ' ', sort { $a <=> $b } @steps;
}

sub maybe_die {
    $opts{force} or die @_;
    print @_;
    print ' overridden by --force';
}

my $fu = CATS::FileUtil->new({ logger => CATS::Logger::Die->new });
my $fr = CATS::FileUtil->new({
    run_debug_log => $opts{verbose},
    logger => CATS::Logger::FH->new(*STDERR),
});

my $step_count = 0;

sub step($&) {
    my ($msg, $action) = @_;
    print colored(sprintf('%2d', ++$step_count), 'bold white'), ". $msg ...";
    if (!%filter_steps || exists $filter_steps{$step_count}) {
        $action->();
        say colored(' ok', 'green');
    }
    else {
        say colored(' skipped', 'cyan');
    }
}

sub step_copy {
    my ($from, $to) = @_;
    step "Copy $from -> $to", sub {
        -e $to and maybe_die "Destination already exists: $to";
        copy($from, $to) or maybe_die $!;
    };
}

step 'Verify install', sub {
    -f 'judge.pl' && -d 'lib' or die 'Must run from cats-judge directory';
    -f 'config.xml' and maybe_die 'Seems to be already installed';
};

step 'Verify git', sub {
    my $x = `git --version` or die 'Git not found';
    $x =~ /^git version/ or die "Git not found: $x";
};

step 'Verify required modules', sub {
    my $lines = $fu->read_lines('cpanfile');
    my @missing = grep !eval "require $_; 1;", map /^requires '(.+)';$/ && $1, @$lines;
    maybe_die join "\n", 'Some required modules not found:', @missing, '' if @missing;
};

step 'Verify optional modules', sub {
    my @bad = grep !eval "require $_; 1;", qw(
        FormalInput
        DBI
        HTTP::Request::Common
        IPC::Run
        LWP::Protocol::https
        LWP::UserAgent
        Term::ReadKey
        WWW:Mechanize);
    warn join "\n", 'Some optional modules not found:', @bad, '' if @bad;
};

step 'Clone submodules', sub {
    system('git submodule update --init');
    $? and maybe_die "Failed: $?, $!";
};

step 'Disable Windows Error Reporting UI', sub {
    CATS::DevEnv::Detector::Utils::disable_windows_error_reporting_ui();
};

my @detected_DEs;
step 'Detect development environments', sub {
    IPC::Cmd->can_capture_buffer or print ' IPC::Cmd is inadequate, will use emulation';
    print "\n";
    CATS::DevEnv::Detector::Utils::disable_error_dialogs();
    for (globq(File::Spec->catfile(qw[lib CATS DevEnv Detector *.pm]))) {
        my ($name) = /(\w+)\.pm$/;
        next if $name =~ /^(Utils|Base)$/ || $opts{devenv} && $name !~ qr/$opts{devenv}/i;
        require $_;
        my $d = "CATS::DevEnv::Detector::$name"->new;
        printf "    Detecting %s:\n", $d->name;
        for (values %{$d->detect}){
            printf "      %s %-12s %s\n",
                ($_->{preferred} ? '*' : $_->{valid} ? ' ' : '?'), $_->{version}, $_->{path};
            push @detected_DEs, { path => $_->{path}, code => $d->code } if ($_->{preferred});
        }
    }
};

my $proxy;
step 'Detect proxy', sub {
    $proxy = CATS::DevEnv::Detector::Utils::detect_proxy() or return;
    print " $proxy ";
    $proxy = "http://$proxy";
};

my $platform;
step 'Detect platform', sub {
    $platform = CATS::Spawner::Platform::get or maybe_die "Unsupported platform: $^O";
    print " $platform" if $platform;
};

step 'Prepare spawner binary', sub {
    $platform or maybe_die "\nDetect platform first";
    my $dir = File::Spec->catdir('spawner-bin', $platform);
    my $make_type = $opts{bin} // 'download';
    -e $dir ?
        (-d $dir or maybe_die "\n$dir is not a directory") :
        make_path $dir or maybe_die "\nCan't create directory $dir";
    if ($make_type =~ qr~^download(:(v(\d+\.)+\d+)(:(\w+)\/(\w+))?)?$~) {
        print "\n";
        my $version = '';
        my $repo_own = 'klenin';
        my $remote_repo = 'Spawner';
        if ($1) {
            $version = $2;
            $repo_own = $5 if $4;
            $remote_repo = $6 if $4;
        }
        else {
            my $tag = `cd Spawner && git describe --tag --match "v[0-9]*"`;
            $tag =~ s/(\n|\r)//g;
            $tag =~ /^v(\d+\.)+\d+$/ or maybe_die "Submodule Spawner does not have valid version tag: $tag";
            $version = $tag;
        }
        print "    Download spawner binary $version...\n";
        my $file = $platform . '.zip';
        unlink $file unless -s $file;
        # File::Fetch does not understand https protocol name but redirect works.
        my $uri = "http://github.com/$repo_own/$remote_repo/releases/download/$version/$file";
        print "    Link: $uri\n";
        if ($proxy) {
            $ENV{http_proxy} = $ENV{https_proxy} = $proxy;
        }
        my $ff = File::Fetch->new(uri => $uri);
        my $bins = -e $file ? $file : $ff->fetch() or maybe_die "Can't download bin files from $uri";
        my $sp = $^O eq 'MSWin32' ? 'sp.exe' : 'sp';
        my $sp_path = File::Spec->catfile($dir, $sp);
        unzip($bins => $sp_path, Name => $sp, BinModeOut => 1) or maybe_die "Can't unzip $bins";
        chmod 0744, $sp_path if $^O ne 'MSWin32';
        unlink $bins;
    }
    else {
        maybe_die 'Unknown --bin value';
    }
};

my @p = qw(lib cats-problem CATS);
step_copy(File::Spec->catfile(@p, 'Config.pm.template'), File::Spec->catfile(@p, 'Config.pm'));

step_copy('config.xml.template', 'config.xml');

step 'Save configuration', sub {
    @detected_DEs || defined $proxy || defined $platform or return;
    open my $conf_in, '<', 'config.xml' or die "Can't open config.xml";
    open my $conf_out, '>', 'config.xml.tmp' or die "Can't open config.xml.tmp";
    my %path_idx;
    $path_idx{$_->{code}} = $_ for @detected_DEs;
    my $flag = 0;
    my $sp = $platform ?
        File::Spec->rel2abs(CATS::Spawner::Platform::get_path($platform)) : undef;
    while (<$conf_in>) {
        s~(\s+proxy=")"~$1$proxy"~ if defined $proxy;
        s~(\sname="#spawner"\s+value=")[^"]+"~$1$sp"~ if defined $platform;
        if (($platform // '') ne 'win32') {
            s~(\sname="#move"\s+value=")[^"]+"~$1/bin/mv -f"~;
            s~(\sname="#gcc_stack"\s+value=")[^"]+"~$1"~;
            # Hack: Use G++ instead of Visual C++
            s~extension='cpp'~extension='cpp1'~;
            s~extension='cxx'~extension='cpp cxx'~;
        }

        $flag = $flag ? $_ !~ m/<!-- END -->/ : $_ =~ m/<!-- This code is touched by install.pl -->/;
        my ($code) = /de_code_autodetect="(\d+)"/;
        s/value="[^"]*"/value="$path_idx{$code}->{path}"/ if $flag && $code && $path_idx{$code};
        print $conf_out $_;
    }
    close $conf_in;
    close $conf_out;
    rename 'config.xml.tmp', 'config.xml' or die "rename: $!";
};

sub parse_xml_file {
    my ($file, %handlers) = @_;
    my $xml_parser = XML::Parser::Expat->new;
    $xml_parser->setHandlers(%handlers);
    $xml_parser->parsefile($file);
}

sub get_dirs {
    -e 'config.xml' or die 'Missing config.xml';
    my ($modulesdir, $cachedir);
    parse_xml_file('config.xml', Start => sub {
        my ($p, $el, %atts) = @_;
        $el eq 'judge' or return;
        $modulesdir = $atts{modulesdir};
        $cachedir = $atts{cachedir};
        $p->finish;
    });
    ($modulesdir, $cachedir);
}

sub check_module {
    my ($module_name, $cachedir) = @_;
    -e $module_name or return;
    my $path = '';
    parse_xml_file($module_name,
        Start => sub {
            my ($p, $el) = @_;
            $p->setHandlers(Char => sub { $path .= $_[1] }) if $el eq 'path';
        },
        End => sub {
            my ($p, $el) = @_;
            $p->finish if $el eq 'path';
        }
    );
    $path or return;
    my ($module_cache) = $path =~ /^(.*\Q$cachedir\E.*)[\\\/]temp/ or return;
    -d $module_cache && -f "$module_cache.des" or return;
    ($fu->read_lines_chomp("$module_cache.des")->[2] // '') eq 'state:ready';
}

step 'Install cats-modules', sub {
    require XML::Parser::Expat;
    # todo use CATS::Judge::Config
    my ($modulesdir, $cachedir) = get_dirs();
    my $cats_modules_dir = File::Spec->catfile(qw[lib cats-modules]);
    my @modules = map +{
        name => $_,
        xml => globq(File::Spec->catfile($cats_modules_dir, $_, '*.xml')),
        dir => [ $cats_modules_dir, $_ ],
        success => 0
    }, grep !$opts{modules} || /$opts{modules}/,
        @{$fu->read_lines_chomp([ $cats_modules_dir, 'modules.txt'])};
    my $jcmd = [ 'cmd', 'j.'. ($^O eq 'MSWin32' ? 'cmd' : 'sh') ];
    print "\n";
    for my $m (@modules) {
        my $run = $fr->run([ $jcmd, 'install', '--problem', $m->{dir} ]);
        $run->ok or print $run->err, next;
        print @{$run->full} if $opts{verbose};
        parse_xml_file($m->{xml}, Start => sub {
            my ($p, $el, %atts) = @_;
            exists $atts{export} or return;
            $m->{total}++;
            my $module_xml = File::Spec->catfile($modulesdir, "$atts{export}.xml");
            $m->{success}++ if check_module($module_xml, $cachedir);
        });
    }
    my $w = max(map length $_->{name}, @modules);
    for my $m (@modules) {
        printf " %*s : %s\n", $w, $m->{name},
            !$m->{success} ? colored('FAILED', 'red'):
            $m->{success} < $m->{total} ? colored("PARTIAL $m->{success}/$m->{total}", 'yellow') :
            colored('ok', 'green');
    }
};

step 'Add j to path', sub {
    print CATS::DevEnv::Detector::Utils::add_to_path(File::Spec->rel2abs('cmd'));
};
