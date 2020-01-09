#!/bin/bash

# Build a modern version of libpq and depending libs from source on Centos 5

set -e -x
set -o pipefail

OPENSSL_VERSION="1.1.1d"
LDAP_VERSION="2.4.48"
SASL_VERSION="2.1.27"
# If you change this, fix WANT_LIBPQ too in .travis.yml
POSTGRES_VERSION="11.5"

yum install -y zlib-devel krb5-devel pam-devel

# Need perl 5.10.0 to build/install openssl
curl -L https://install.perlbrew.pl | bash
source ~/perl5/perlbrew/etc/bashrc
perlbrew install --notest perl-5.16.0
perlbrew switch perl-5.16.0

# Build openssl if needed
OPENSSL_TAG="OpenSSL_${OPENSSL_VERSION//./_}"
OPENSSL_DIR="openssl-${OPENSSL_TAG}"
if [ ! -d "${OPENSSL_DIR}" ]; then curl -sL \
        https://github.com/openssl/openssl/archive/${OPENSSL_TAG}.tar.gz \
        | tar xzf -

    cd "${OPENSSL_DIR}"

    # Expose the lib version number in the .so file name
    sed -i "s/SHLIB_VERSION_NUMBER\s\+\".*\""\
"/SHLIB_VERSION_NUMBER \"${OPENSSL_VERSION}\"/" \
        ./include/openssl/opensslv.h
    sed -i "s|if (\$shlib_version_number =~ /(^\[0-9\]\*)\\\.(\[0-9\\\.\]\*)/)"\
"|if (\$shlib_version_number =~ /(^[0-9]*)\.([0-9\.]*[a-z]?)/)|" \
        ./Configure

    ./config --prefix=/usr/local/ --openssldir=/usr/local/ \
        zlib -fPIC shared
    make depend
    make

    # Check the shlib built has the correct version number in the name
    if [[ ! -f "./libssl.so.${OPENSSL_VERSION}" ]]; then
        echo >&2 "libssl.so.${OPENSSL_VERSION} not found, there is $(ls libssl.so.*)"
        exit 1
    fi
else
    cd "${OPENSSL_DIR}"
fi

# Install openssl
make install
cd ..


# Build libsasl2 if needed
# The system package (cyrus-sasl-devel) causes an amazing error on i686:
# "unsupported version 0 of Verneed record"
# https://github.com/pypa/manylinux/issues/376
SASL_TAG="cyrus-sasl-${SASL_VERSION}"
SASL_DIR="cyrus-sasl-${SASL_TAG}"
if [ ! -d "${SASL_DIR}" ]; then
    curl -sL \
        https://github.com/cyrusimap/cyrus-sasl/archive/${SASL_TAG}.tar.gz \
        | tar xzf -

    cd "${SASL_DIR}"

    autoreconf -i
    ./configure
    make
else
    cd "${SASL_DIR}"
fi

# Install libsasl2
# requires missing nroff to build
touch saslauthd/saslauthd.8
make install
cd ..


# Build openldap if needed
LDAP_TAG="${LDAP_VERSION}"
LDAP_DIR="openldap-${LDAP_TAG}"
if [ ! -d "${LDAP_DIR}" ]; then
    curl -sL \
        https://www.openldap.org/software/download/OpenLDAP/openldap-release/openldap-${LDAP_TAG}.tgz \
        | tar xzf -

    cd "${LDAP_DIR}"

    ./configure --enable-backends=no --enable-null
    make depend
    (cd libraries/liblutil/ && make)
    (cd libraries/liblber/ && make)
    (cd libraries/libldap/ && make)
    (cd libraries/libldap_r/ && make)
else
    cd "${LDAP_DIR}"
fi

# Install openldap
(cd libraries/liblber/ && make install)
(cd libraries/libldap/ && make install)
(cd libraries/libldap_r/ && make install)
(cd include/ && make install)
chmod +x /usr/local/lib/{libldap,liblber}*.so*
cd ..


# Build libpq if needed
# This recipe is very similar to that in build_libpq_macos.sh
# Consider keeping them in sync.
POSTGRES_TAG="REL_${POSTGRES_VERSION//./_}"
POSTGRES_DIR="postgres-${POSTGRES_TAG}"
if [ ! -d "${POSTGRES_DIR}" ]; then
    curl -sL \
        https://github.com/postgres/postgres/archive/${POSTGRES_TAG}.tar.gz \
        | tar xzf -

    cd "${POSTGRES_DIR}"

    # Match the default unix socket dir default with what defined on Ubuntu and
    # Red Hat, which seems the most common location
    sed -i 's|#define DEFAULT_PGSOCKET_DIR .*'\
'|#define DEFAULT_PGSOCKET_DIR "/var/run/postgresql"|' \
        src/include/pg_config_manual.h

    ./configure --prefix=/usr/local --without-readline \
        --with-gssapi --with-openssl --with-pam --with-ldap
    (cd src/interfaces/libpq && make)
    (cd src/bin/pg_config && make)
    # This will fail after installing postgres_fe.h, which is what we need
    (cd src/include && make)
else
    cd "${POSTGRES_DIR}"
fi

# Install libpq
(cd src/interfaces/libpq && make install)
(cd src/bin/pg_config && make install)
# This will fail after installing postgres_fe.h, which is the bit we need
(cd src/include && make install || true)
cd ..

find /usr/local/ -name \*.so.\* -type f -exec strip --strip-unneeded {} \;
