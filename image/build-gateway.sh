#!/bin/bash
#
# This script is expected to run inside a docker container which has the Raspberry Pi toolchain
# and required prerequisites:
#   - pkg-config
#   - libusb-1.0-0-dev
#   - libudev-dev
#
# /build corresponds to the current directory when the docker container is run and it is expected
# that the following directory structure has been setup:
#
#   - /build/Open-ZWave/open-zwave  - git repository containing the desired version of OpenZWave
#   - /build/gateway                - git repository containing the gateway software

set -e

NVM_VERSION="v0.33.8"
NODE_VERSION="--lts=carbon"

GATEWAY=gateway
OPEN_ZWAVE=OpenZWave/open-zwave

GATEWAY_TARBALL=gateway.tar.gz
OPENZWAVE_TARBALL=openzwave.tar.gz

ARCH=armv6l
SYSROOT=/rpxc/sysroot

# Remove the output, if it exists
rm -f ${GATEWAY_TARBALL} ${OPENZWAVE_TARBALL}

# Clean any previous build of Open-ZWave
make -C ${OPEN_ZWAVE} clean

# Clean any previous node modules
rm -rf ${GATEWAY}/node_modules

# Under rpxc /rpxc/sysroot/usr/lib/arm-linux-gnueabihf/libudev.so is
# a symlink back to /lib/arm-linux-gnueabihf/libudev.so.1.5.0 which
# doesn't exist. So we go ahead and create a symlink there and point
# it to the same path under /rpxc/sysroot
#
# My guess is that this would be fine for chrooted apps, but I don't
# think that the cross compilers run chrooted.
LIBUDEV_SO=/lib/arm-linux-gnueabihf/libudev.so.1.5.0
sudo mkdir -p $(dirname ${LIBUDEV_SO})
sudo ln -s ${SYSROOT}/${LIBUDEV_SO} ${LIBUDEV_SO}

# Cross compile Open-ZWave
PREFIX=/usr CFLAGS=--sysroot=${SYSROOT} LDFLAGS=--sysroot=${SYSROOT} make -C ${OPEN_ZWAVE} CROSS_COMPILE=arm-linux-gnueabihf-

# Install Open-ZWave
# Technically, this is incorrect. We should be setting DESTDIR to ${SYSROOT}.
# By not setting DESTDIR we wind up installing the ARM version of
# libopenzwave into the host tree. The openzwave-shared node module uses
# pkg-config to determine where openzwave is installed and expects that the
# build tree and the install tree are the same. The host build doesn't need to
# use openzwave, so we can get away with this sleight of hand for now.
INSTALL_OPENZWAVE="PREFIX=/usr make  -C ${OPEN_ZWAVE} CROSS_COMPILE=arm-linux-gnueabihf- MACHINE=${ARCH} install"
sudo ${INSTALL_OPENZWAVE}
sudo DESTDIR=${SYSROOT} ${INSTALL_OPENZWAVE}

# Setup Cross compiler vars which are used by node-gyp when building native node modules.
OPTS="--sysroot=${SYSROOT}"
export CC="arm-linux-gnueabihf-gcc ${OPTS}"
export CXX="arm-linux-gnueabihf-g++ ${OPTS}"

# Install and configure nvm
curl -o- https://raw.githubusercontent.com/creationix/nvm/${NVM_VERSION}/install.sh | bash
# The following 2 lines are installed into ~/.bashrc by the above,
# but on the RPi, sourcing ~/.bashrc winds up being a no-op (when sourced
# from a script), so we just run it here.
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"  # This loads nvm
nvm install ${NODE_VERSION}
nvm use ${NODE_VERSION}

npm install -g yarn

# Build the node modules, cross compiling any native code.
(cd ${GATEWAY}; yarn --ignore-scripts; npm rebuild --arch=${ARCH} --target_arch=arm; node_modules/.bin/webpack)

set -x

# Create a tarball with the gateway project, including node_modules
tar czf ${GATEWAY_TARBALL} ${GATEWAY}

# Create a tarball with the OpenZWave files needed to run the gateway

# NOTE: We need to use cd (instead of -C) so that the libopenzwave* wildcard
#       will be expanded properly.
OZW_TGZ=$(pwd)/${OPENZWAVE_TARBALL}
(cd /; tar czf ${OZW_TGZ} usr/include/openzwave usr/lib/libopenzwave* usr/etc/openzwave)

echo "Done"
