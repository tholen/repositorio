#
# (c) Jan Gehring <jan.gehring@gmail.com>
#
# vim: set ts=2 sw=2 tw=0:
# vim: set expandtab:

package Rex::Repositorio;

use Moose;
use English;
use common::sense;
use Carp;
use LWP::UserAgent;
use XML::LibXML;
use XML::Simple;
use Params::Validate qw(:all);
use IO::All;
use File::Path;
use File::Basename qw'dirname';
use File::Spec;
use File::Copy;
use Rex::Repositorio::Repository_Factory;

our $VERSION = "0.2.0";

has config => ( is => 'ro' );
has logger => ( is => 'ro' );
has ua     => (
  is      => 'ro',
  default => sub {
    my $ua = LWP::UserAgent->new;
    $ua->env_proxy;
    return $ua;
  }
);

sub run {
  my ( $self, %option ) = @_;

  $self->config->{RepositoryRoot} =~ s/\/$//;
  $self->parse_cli_option(%option);
}

sub parse_cli_option {
  my ( $self, %option ) = @_;

  if ( exists $option{help} ) {
    $self->_help();
    exit 0;
  }

  if ( exists $option{mirror} && exists $option{repo} ) {
    $self->mirror(
      repo            => $option{repo},
      update_metadata => $option{"update-metadata"},
      update_files    => $option{"update-files"},
    );
  }

  elsif ( exists $option{tag} && exists $option{repo} ) {
    $self->tag( tag => $option{tag}, repo => $option{repo} );
  }

  elsif ( exists $option{list} ) {
    $self->list();
  }

  elsif ( exists $option{init} && exists $option{repo} ) {
    $self->init( repo => $option{repo} );
  }

  elsif ( exists $option{"add-file"} && exists $option{repo} ) {
    $self->add_file( file => $option{"add-file"}, repo => $option{repo} );
  }

  elsif ( exists $option{"remove-file"} && exists $option{repo} ) {
    $self->remove_file( file => $option{"remove-file"}, repo => $option{repo} );
  }

  else {
    $self->_help();
    exit 0;
  }
}

sub add_file {
  my $self   = shift;
  my %option = validate(
    @_,
    {
      file => {
        type => SCALAR
      },
      repo => {
        type => SCALAR
      }
    }
  );

  my $repo   = $self->config->{Repository}->{ $option{repo} };
  my $type   = $repo->{type};
  my $repo_o = Rex::Repositorio::Repository_Factory->create(
    type    => $type,
    options => {
      app  => $self,
      repo => {
        name => $option{repo},
        %{$repo},
      }
    }
  );

  $repo_o->add_file( file => $option{file} );
}

sub remove_file {
  my $self   = shift;
  my %option = validate(
    @_,
    {
      file => {
        type => SCALAR
      },
      repo => {
        type => SCALAR
      }
    }
  );

  my $repo   = $self->config->{Repository}->{ $option{repo} };
  my $type   = $repo->{type};
  my $repo_o = Rex::Repositorio::Repository_Factory->create(
    type    => $type,
    options => {
      app  => $self,
      repo => {
        name => $option{repo},
        %{$repo},
      }
    }
  );

  $repo_o->remove_file( file => $option{file} );
}

sub list {
  my $self  = shift;
  my @repos = keys %{ $self->config->{Repository} };

  $self->_print(@repos);
}

sub init {
  my $self   = shift;
  my %option = validate(
    @_,
    {
      repo => {
        type => SCALAR
      }
    }
  );

  my $repo = $self->config->{Repository}->{ $option{repo} };

  if ( !$repo ) {
    $self->logger->error("Repository $option{repo} not found.");
    confess "Repository $option{repo} not found.";
  }

  my $type   = $repo->{type};
  my $repo_o = Rex::Repositorio::Repository_Factory->create(
    type    => $type,
    options => {
      app  => $self,
      repo => {
        name => $option{repo},
        %{$repo},
      }
    }
  );

  $repo_o->verify_options;
  $repo_o->init;
}

sub mirror {
  my $self   = shift;
  my %option = validate(
    @_,
    {
      repo => {
        type => SCALAR
      },
      update_metadata => {
        type     => BOOLEAN,
        optional => 1,
      },
      update_files => {
        type     => BOOLEAN,
        optional => 1,
      },
    }
  );

  my @repositories = ( $option{repo} );
  if ( $option{repo} eq "all" ) {
    @repositories = keys %{ $self->config->{Repository} };
  }

  for my $repo (@repositories) {
    my $type = $self->config->{Repository}->{$repo}->{type};

    my $repo_o = Rex::Repositorio::Repository_Factory->create(
      type    => $type,
      options => {
        app  => $self,
        repo => {
          name => $repo,
          %{ $self->config->{Repository}->{$repo} },
        }
      }
    );

    $repo_o->mirror(
      update_metadata => $option{update_metadata},
      update_files    => $option{update_files}
    );
  }
}

sub tag {
  my $self   = shift;
  my %option = validate(
    @_,
    {
      repo => {
        type => SCALAR
      },
      tag => {
        type => SCALAR
      },
    }
  );

  my $repo_config = $self->config->{Repository}->{ $option{repo} };
  my $root_dir    = $self->config->{RepositoryRoot};
  $repo_config->{local} =~ s/\/$//;

  my @dirs    = ("$root_dir/head/$repo_config->{local}");
  my $tag_dir = "$root_dir/$option{tag}/$repo_config->{local}";

  mkpath $tag_dir;

  for my $dir (@dirs) {
    opendir my $dh, $dir;
    while ( my $entry = readdir $dh ) {
      next if ( $entry eq "." || $entry eq ".." );
      my $rel_entry = "$dir/$entry";
      $rel_entry =~ s/$root_dir\/head\/$repo_config->{local}\///;

      if ( -d "$dir/$entry" ) {
        push @dirs, "$dir/$entry";
        $self->logger->debug("Creating directory: $tag_dir/$rel_entry.");
        mkdir "$tag_dir/$rel_entry";
        next;
      }

      $self->logger->debug(
        "Linking (hard): $dir/$entry -> $tag_dir/$rel_entry");
      link "$dir/$entry", "$tag_dir/$rel_entry";
    }
    closedir $dh;
  }
}

sub get_repo_dir {
  my $self   = shift;
  my %option = validate(
    @_,
    {
      repo => {
        type => SCALAR
      }
    }
  );

  return File::Spec->rel2abs( $self->config->{RepositoryRoot}
      . "/head/"
      . $self->config->{Repository}->{ $option{repo} }->{local} );
}

sub _print {
  my $self  = shift;
  my @lines = @_;

  print "repositorio: $VERSION\n";
  print "-" x 80;
  print "\n";
  print "$_\n" for @lines;
}

sub _help {
  my ($self) = @_;

  $self->_print(
    "--mirror            mirror a configured repository (needs --repo)",
    "--tag=tagname       tag a repository (needs --repo)",
    "--repo=reponame     the name of the repository to use",
    "--update-metadata   update the metadata of a repository",
    "--update-files      download files even if they are already downloaded",
    "--init              initialize an empty repository",
    "--add-file=file     add a file to a repository (needs --repo)",
    "--remove-file=file  remove a file from a repository (needs --repo)",
    "--list              list known repositories",
    "--help              display this help message",
  );

}

1;

__END__

=pod

=head1 repositor.io - Linux Repository Management

repositor.io is a tool to create and manage linux repositories.
You can mirror online repositories so that you don't need to download the
package every time you set up a new server. You can also secure your servers
behind a firewall and disable outgoing http traffic.

With repositor.io it is easy to create custom repositories for your own
packages. With the integration of a configuration management tool you can
create consistant installations of your server.

=head2 GETTING HELP

=over 4

=item * Web Site: L<http://repositor.io/>

=item * IRC: irc.freenode.net #repositorio

=item * Bug Tracker: L<https://github.com/krimdomu/repositorio/issues>

=item * Twitter: L<http://twitter.com/jfried83>

=back

=head2 COMMAND LINE

=over 4

=item --mirror            mirror a configured repository (needs --repo)

=item --tag=tagname       tag a repository (needs --repo)

=item --repo=reponame     the name of the repository to use

=item --update-metadata   update the metadata of a repository

=item --update-files      download files even if they are already downloaded

=item --init              initialize an empty repository

=item --add-file=file     add a file to a repository (needs --repo)

=item --remove-file=file  remove a file from a repository (needs --repo)

=item --list              list known repositories

=item --help              display this help message

=back

=head2 CONFIGURATION

To configure repositor.io create a configuration file
I</etc/rex/repositorio.conf>.
 RepositoryRoot = /srv/html/repo/
   
 # log4perl configuration file
 <Log4perl>
   config = /etc/rex/io/log4perl.conf
 </Log4perl>
   
 # create a mirror of the nightly rex repository
 # the files will be stored in
 # /srv/html/repo/head/rex-centos-6-x86-64/CentOS/6/rex/x86_64/
 <Repository rex-centos-6-x86-64>
   url   = http://nightly.rex.linux-files.org/CentOS/6/rex/x86_64/
   local = rex-centos-6-x86-64/CentOS/6/rex/x86_64/
   type  = Yum
 </Repository>
   
 # create a mirror of centos 6
 # and download the pxe boot files, too.
 <Repository centos-6-x86-64>
   url    = http://ftp.hosteurope.de/mirror/centos.org/6/os/x86_64/
   local  = centos-6-x86-64/CentOS/6/os/x86_64/
   type   = Yum
   images = true
 </Repository>
   
 # create a custom repository
 <Repository centos-6-x86-64-mixed>
   local = centos-6-x86-64-mixed/mixed/6/x86_64/
   type  = Yum
 </Repository>
   
 <Repository debian-wheezy-i386-main>
   url       = http://ftp.de.debian.org/debian/
   local     = debian-wheezy-amd64-main/debian
   type      = Apt
   arch      = i386
   dist      = wheezy
   component = main
 </Repository>
 
If you want to sign your custom repositories you have to configure the gpg key to use.
repositorio automatically exports the public key into the root of the repository, so it can be imported from the clients.
If you don't specify the gpg password repositorio will ask you for the password.

An example for YUM repositories:

 <Repository centos-6-x86-64-mixed>
   local = centos-6-x86-64-mixed/mixed/6/x86_64/
   type  = Yum
   <gpg>
     key      = DA95F273
     password = test
   </gpg>
 </Repository>

An example for APT repositories:

 <Repository debian-7-x86-64-mixed>
   local     = debian-7-x86-64-mixed/debian
   type      = Apt
   arch      = amd64
   dist      = wheezy
   component = mixed
   <gpg>
     key      = DA95F273
     password = test
   </gpg>
 </Repository>

An example log4perl.conf file:

 log4perl.rootLogger                    = DEBUG, FileAppndr1

 log4perl.appender.FileAppndr1          = Log::Log4perl::Appender::File
 log4perl.appender.FileAppndr1.filename = /var/log/repositorio.log
 log4perl.appender.FileAppndr1.layout   = Log::Log4perl::Layout::SimpleLayout
