use ExtUtils::MakeMaker;

WriteMakefile(
	NO_META   => 1,
	NAME            => 'ORM::Easy',
    VERSION_FROM    => 'lib/ORM/Easy.pm'
);

sub MY::postamble { 
	return qq[
SHAREDIR="\$(PREFIX)/share/orm-easy"
install_sql: 
	test -d \$(SHAREDIR) || mkdir -p \$(SHAREDIR)
	cp -r sql/*.sql \$(SHAREDIR)
install :: install_sql
]; 
}
