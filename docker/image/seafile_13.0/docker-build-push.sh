
#!/bin/bash

version=$1

docker build --pull --build-arg server_version=$version -t ${SEAFILE_IMAGE_NAME:-ghcr.io/felixbennettio/seafile-next-server}:${version}-testing ./



docker push ${SEAFILE_IMAGE_NAME:-ghcr.io/felixbennettio/seafile-next-server}:${version}-testing



echo ${SEAFILE_IMAGE_NAME:-ghcr.io/felixbennettio/seafile-next-server}:${version}-testing
