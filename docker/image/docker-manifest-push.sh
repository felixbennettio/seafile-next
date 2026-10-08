#!/bin/bash

version=$1
first_num=$(echo $version | cut -d '.' -f1)
second_num=$(echo $version | cut -d '.' -f2)

docker manifest rm ${SEAFILE_IMAGE_NAME:-ghcr.io/felixbennettio/seafile-next-server}:${first_num}.${second_num}-latest

docker manifest create ${SEAFILE_IMAGE_NAME:-ghcr.io/felixbennettio/seafile-next-server}:${first_num}.${second_num}-latest ${SEAFILE_IMAGE_NAME:-ghcr.io/felixbennettio/seafile-next-server}:${version}-testing ${SEAFILE_IMAGE_NAME:-ghcr.io/felixbennettio/seafile-next-server}:${version}-arm-testing

docker manifest push ${SEAFILE_IMAGE_NAME:-ghcr.io/felixbennettio/seafile-next-server}:${first_num}.${second_num}-latest



docker manifest rm ${SEAFILE_IMAGE_NAME:-ghcr.io/felixbennettio/seafile-next-server}:${version}

docker manifest create ${SEAFILE_IMAGE_NAME:-ghcr.io/felixbennettio/seafile-next-server}:${version} ${SEAFILE_IMAGE_NAME:-ghcr.io/felixbennettio/seafile-next-server}:${version}-testing ${SEAFILE_IMAGE_NAME:-ghcr.io/felixbennettio/seafile-next-server}:${version}-arm-testing

docker manifest push ${SEAFILE_IMAGE_NAME:-ghcr.io/felixbennettio/seafile-next-server}:${version}



echo ${SEAFILE_IMAGE_NAME:-ghcr.io/felixbennettio/seafile-next-server}:${first_num}.${second_num}-latest
echo ${SEAFILE_IMAGE_NAME:-ghcr.io/felixbennettio/seafile-next-server}:${version}
