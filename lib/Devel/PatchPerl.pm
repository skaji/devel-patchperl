package Devel::PatchPerl;

# ABSTRACT: Patch perl source a la Devel::PPort's buildperl.pl

use strict;
use warnings;
use File::pushd qw[pushd];
use File::Spec;
use IO::File;
use IPC::Cmd qw[can_run run];
use vars qw[@ISA @EXPORT_OK];

@ISA       = qw(Exporter);
@EXPORT_OK = qw(patch_source);

my $patch_exe = can_run('patch');

my @patch = (
  {
    perl => [
              qr/^5\.00[01234]/,
              qw/
                5.005
                5.005_01
                5.005_02
                5.005_03
              /,
            ],
    subs => [
              [ \&_patch_db, 1 ],
            ],
  },
  {
    perl => [
            qw/
                5.6.0
                5.6.1
                5.7.0
                5.7.1
                5.7.2
                5.7.3
                5.8.0
            /,
            ],
    subs => [
              [ \&_patch_db, 3 ],
            ],
  },
  {
    perl => [
              qr/^5\.004_0[1234]$/,
            ],
    subs => [
              [ \&_patch_doio ],
            ],
  },
  {
    perl => [
              qw/
                5.005
                5.005_01
                5.005_02
              /,
            ],
    subs => [
              [ \&_patch_sysv, old_format => 1 ],
            ],
  },
  {
    perl => [
              qw/
                5.005_03
                5.005_04
              /,
              qr/^5\.6\.[0-2]$/,
              qr/^5\.7\.[0-3]$/,
              qr/^5\.8\.[0-8]$/,
              qr/^5\.9\.[0-5]$/
            ],
    subs => [
              [ \&_patch_sysv ],
            ],
  },
  {
    perl => [
              qr/^5\.004_05$/,
              qr/^5\.005(?:_0[1-4])?$/,
              qr/^5\.6\.[01]$/,
            ],
    subs => [
              [ \&_patch_configure ],
              [ \&_patch_makedepend_lc ],
            ],
  },
  {
    perl => [
              '5.8.0',
            ],
    subs => [
              [ \&_patch_makedepend_lc ],
            ],
  },
  {
    perl => [
              qr/.*/,
            ],
    subs => [
              [ \&_patch_nbsd_hints ],
            ],
  },
);

sub patch_source {
  my $vers = shift;
  $vers = shift if eval { $vers->isa(__PACKAGE__) };
  my $source = shift || '.';
  $source = File::Spec->rel2abs($source);
  warn "No patch utility found\n" unless $patch_exe;
  {
    my $dir = pushd( $source );
    for my $p ( grep { _is( $_->{perl}, $vers ) } @patch ) {
       for my $s (@{$p->{subs}}) {
         my($sub, @args) = @$s;
         $sub->(@args);
       }
    }
  }
}

sub _is
{
  my($s1, $s2) = @_;

  defined $s1 != defined $s2 and return 0;

  ref $s2 and ($s1, $s2) = ($s2, $s1);

  if (ref $s1) {
    if (ref $s1 eq 'ARRAY') {
      _is($_, $s2) and return 1 for @$s1;
      return 0;
    }
    return $s2 =~ $s1;
  }

  return $s1 eq $s2;
}

sub _patch_db
{
  my $ver = shift;
  print "patching ext/DB_File/DB_File.xs\n";
  _run_or_die($^X, '-pi.bak', '-e', "s/<db.h>/<db$ver\\/db.h>/", 'ext/DB_File/DB_File.xs');
  unlink 'ext/DB_File/DB_File.xs.bak' if -e 'ext/DB_File/DB_File.xs.bak';
}

sub _patch_doio
{
  _patch(<<'END');
--- doio.c.org  2004-06-07 23:14:45.000000000 +0200
+++ doio.c  2003-11-04 08:03:03.000000000 +0100
@@ -75,6 +75,16 @@
 #  endif
 #endif

+#if _SEM_SEMUN_UNDEFINED
+union semun
+{
+  int val;
+  struct semid_ds *buf;
+  unsigned short int *array;
+  struct seminfo *__buf;
+};
+#endif
+
 bool
 do_open(gv,name,len,as_raw,rawmode,rawperm,supplied_fp)
 GV *gv;
END
}

sub _patch_sysv
{
  my %opt = @_;

  # check if patching is required
  return if $^O ne 'linux' or -f '/usr/include/asm/page.h';

  if ($opt{old_format}) {
    _patch(<<'END');
--- ext/IPC/SysV/SysV.xs.org  1998-07-20 10:20:07.000000000 +0200
+++ ext/IPC/SysV/SysV.xs  2007-08-12 10:51:06.000000000 +0200
@@ -3,9 +3,6 @@
 #include "XSUB.h"
 
 #include <sys/types.h>
-#ifdef __linux__
-#include <asm/page.h>
-#endif
 #if defined(HAS_MSG) || defined(HAS_SEM) || defined(HAS_SHM)
 #include <sys/ipc.h>
 #ifdef HAS_MSG
END
  }
  else {
    _patch(<<'END');
--- ext/IPC/SysV/SysV.xs.org  2007-08-11 00:12:46.000000000 +0200
+++ ext/IPC/SysV/SysV.xs  2007-08-11 00:10:51.000000000 +0200
@@ -3,9 +3,6 @@
 #include "XSUB.h"
 
 #include <sys/types.h>
-#ifdef __linux__
-#   include <asm/page.h>
-#endif
 #if defined(HAS_MSG) || defined(HAS_SEM) || defined(HAS_SHM)
 #ifndef HAS_SEM
 #   include <sys/ipc.h>
END
  }
}

sub _patch_configure
{
  _patch(<<'END');
--- Configure
+++ Configure
@@ -3380,6 +3380,18 @@
 test "X$gfpthkeep" != Xy && gfpth=""
 EOSC
 
+# gcc 3.1 complains about adding -Idirectories that it already knows about,
+# so we will take those off from locincpth.
+case "$gccversion" in
+3*)
+    echo "main(){}">try.c
+    for incdir in `$cc -v -c try.c 2>&1 | \
+       sed '1,/^#include <\.\.\.>/d;/^End of search list/,$d;s/^ //'` ; do
+       locincpth=`echo $locincpth | sed s!$incdir!!`
+    done
+    $rm -f try try.*
+esac
+
 : What should the include directory be ?
 echo " "
 $echo $n "Hmm...  $c"
END
}

sub _patch_makedepend_lc
{
  _patch(<<'END');
--- makedepend.SH
+++ makedepend.SH
@@ -58,6 +58,10 @@ case $PERL_CONFIG_SH in
       ;;
 esac
 
+# Avoid localized gcc/cc messages
+LC_ALL=C
+export LC_ALL
+
 # We need .. when we are in the x2p directory if we are using the
 # cppstdin wrapper script.
 # Put .. and . first so that we pick up the present cppstdin, not
END
}

sub _patch_nbsd_hints {
return unless $^O eq 'netbsd';
chmod 0755, 'hints/netbsd.sh' or die "$!\n";
open my $fh, '>', 'hints/netbsd.sh' or die "$\n";
print $fh <<BADGER;
# hints/netbsd.sh
case "\$archname" in
'')
    archname=`uname -m`-\${osname}
    ;;
esac

case "\$osvers" in
0.9|0.8*)
	usedl="\$undef"
	;;
*)
	case `uname -m` in
	pmax)
		# NetBSD 1.3 and 1.3.1 on pmax shipped an `old' ld.so,
		# which will not work.
		case "\$osvers" in
		1.3|1.3.1)
			d_dlopen=\$undef
			;;
		esac
		;;
	esac
	if test -f /usr/libexec/ld.elf_so; then
		# ELF
		d_dlopen=\$define
		d_dlerror=\$define
		cccdlflags="-DPIC -fPIC \$cccdlflags"
		lddlflags="--whole-archive -shared \$lddlflags"
		rpathflag="-Wl,-rpath,"
		case "\$osvers" in
		1.[0-5]*)
			ccdlflags="-Wl,-whole-archive -lgcc \
				-Wl,-no-whole-archive -Wl,-E \$ccdlflags"
			;;
		*)
			ccdlflags="-Wl,-E \$ccdlflags"
			;;
		esac
	elif test -f /usr/libexec/ld.so; then
		# a.out
		d_dlopen=\$define
		d_dlerror=\$define
		cccdlflags="-DPIC -fPIC \$cccdlflags"
		lddlflags="-Bshareable \$lddlflags"
		rpathflag="-R"
	else
		d_dlopen=\$undef
		rpathflag=
	fi
	;;
esac

case "\$osvers" in
0.9*|1.[012]*|1.3|1.3.1)
	d_setregid="\$undef"
	d_setreuid="\$undef"
	;;
esac
case "\$osvers" in
0.9*|1.*|2.*|3.*|4.*|5.*)
	d_getprotoent_r="\$undef"
	d_getprotobyname_r="\$undef"
	d_getprotobynumber_r="\$undef"
	d_setprotoent_r="\$undef"
	d_endprotoent_r="\$undef"
	d_getservent_r="\$undef"
	d_getservbyname_r="\$undef"
	d_getservbyport_r="\$undef"
	d_setservent_r="\$undef"
	d_endservent_r="\$undef"
	d_getprotoent_r_proto="0"
	d_getprotobyname_r_proto="0"
	d_getprotobynumber_r_proto="0"
	d_setprotoent_r_proto="0"
	d_endprotoent_r_proto="0"
	d_getservent_r_proto="0"
	d_getservbyname_r_proto="0"
	d_getservbyport_r_proto="0"
	d_setservent_r_proto="0"
	d_endservent_r_proto="0"
	;;
esac

# These are obsolete in any netbsd.
d_setrgid="\$undef"
d_setruid="\$undef"

# there's no problem with vfork.
usevfork=true

# This is there but in machine/ieeefp_h.
ieeefp_h="define"

# This script UU/usethreads.cbu will get 'called-back' by Configure
# after it has prompted the user for whether to use threads.
cat > UU/usethreads.cbu <<'EOCBU'
case "\$usethreads" in
\$define|true|[yY]*)
	lpthread=
	for xxx in pthread; do
		for yyy in \$loclibpth \$plibpth \$glibpth dummy; do
			zzz=\$yyy/lib\$xxx.a
			if test -f "\$zzz"; then
				lpthread=\$xxx
				break;
			fi
			zzz=\$yyy/lib\$xxx.so
			if test -f "\$zzz"; then
				lpthread=\$xxx
				break;
			fi
			zzz=`ls \$yyy/lib\$xxx.so.* 2>/dev/null`
			if test "X\$zzz" != X; then
				lpthread=\$xxx
				break;
			fi
		done
		if test "X\$lpthread" != X; then
			break;
		fi
	done
	if test "X\$lpthread" != X; then
		# Add -lpthread.
		libswanted="\$libswanted \$lpthread"
		# There is no libc_r as of NetBSD 1.5.2, so no c -> c_r.
		# This will be revisited when NetBSD gains a native pthreads
		# implementation.
	else
		echo "\$0: No POSIX threads library (-lpthread) found.  " \
		     "You may want to install GNU pth.  Aborting." >&4
		exit 1
	fi
	unset lpthread

	# several reentrant functions are embeded in libc, but haven't
	# been added to the header files yet.  Let's hold off on using
	# them until they are a valid part of the API
	case "\$osvers" in
	[012].*|3.[0-1])
		d_getprotobyname_r=\$undef
		d_getprotobynumber_r=\$undef
		d_getprotoent_r=\$undef
		d_getservbyname_r=\$undef
		d_getservbyport_r=\$undef
		d_getservent_r=\$undef
		d_setprotoent_r=\$undef
		d_setservent_r=\$undef
		d_endprotoent_r=\$undef
		d_endservent_r=\$undef ;;
	esac
	;;

esac
EOCBU

# Set sensible defaults for NetBSD: look for local software in
# /usr/pkg (NetBSD Packages Collection) and in /usr/local.
#
loclibpth="/usr/pkg/lib /usr/local/lib"
locincpth="/usr/pkg/include /usr/local/include"
case "\$rpathflag" in
'')
	ldflags=
	;;
*)
	ldflags=
	for yyy in \$loclibpth; do
		ldflags="\$ldflags \$rpathflag\$yyy"
	done
	;;
esac

case `uname -m` in
alpha)
    echo 'int main() {}' > try.c
    gcc=`\${cc:-cc} -v -c try.c 2>&1|grep 'gcc version egcs-2'`
    case "\$gcc" in
    '' | "gcc version egcs-2.95."[3-9]*) ;; # 2.95.3 or better okay
    *)	cat >&4 <<EOF
***
*** Your gcc (\$gcc) is known to be
*** too buggy on netbsd/alpha to compile Perl with optimization.
*** It is suggested you install the lang/gcc package which should
*** have at least gcc 2.95.3 which should work okay: use for example
*** Configure -Dcc=/usr/pkg/gcc-2.95.3/bin/cc.  You could also
*** Configure -Doptimize=-O0 to compile Perl without any optimization
*** but that is not recommended.
***
EOF
	exit 1
	;;
    esac
    rm -f try.*
    ;;
esac

# NetBSD/sparc 1.5.3/1.6.1 dumps core in the semid_ds test of Configure.
case `uname -m` in
sparc) d_semctl_semid_ds=undef ;;
esac
BADGER
close $fh;
}

sub _patch
{
  my($patch) = @_;
  print "patching $_\n" for $patch =~ /^\+{3}\s+(\S+)/gm;
  my $diff = 'tmp.diff';
  _write_or_die($diff, $patch);
  _run_or_die("$patch_exe -s -p0 <$diff");
  unlink $diff or die "unlink $diff: $!\n";
}

sub _write_or_die
{
  my($file, $data) = @_;
  my $fh = IO::File->new(">$file") or die "$file: $!\n";
  $fh->print($data);
}

sub _run_or_die
{
  # print "[running @_]\n";
  die unless scalar run( command => [ @_ ], verbose => 1 );
}

qq[patchin'];

=pod

=head1 SYNOPSIS

  use strict;
  use warnings;

  use Devel::PatchPerl;

  Devel::PatchPerl->patch_source( '5.6.1', '/path/to/untarred/perl/source/perl-5.6.1' );

=head1 DESCRIPTION

Devel::PatchPerl is a modularisation of the patching code contained in L<Devel::PPort>'s 
C<buildperl.pl>.

It does not build perls, it merely provides an interface to the source patching 
functionality.

=head1 FUNCTION

=over

=item C<patch_source>

Takes two parameters, a C<perl> version and the path to unwrapped perl source for that version.
It dies on any errors.

=back

=head1 SEE ALSO

L<Devel::PPPort>

=cut
