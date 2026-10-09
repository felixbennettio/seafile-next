#!/usr/bin/env python3
"""Remove public build attestations without rebuilding or changing image layers."""
import argparse
import base64
import hashlib
import json
import os
import re
import urllib.error
import urllib.parse
import urllib.request

IMAGE = 'felixbennettio/seafile-next-server'
INDEX = 'application/vnd.oci.image.index.v1+json'
MANIFEST = 'application/vnd.oci.image.manifest.v1+json'


def digest(data):
    return 'sha256:' + hashlib.sha256(data).hexdigest()


def sanitize_index(document):
    if document.get('schemaVersion') != 2 or document.get('mediaType') != INDEX:
        raise ValueError('Expected an OCI image index')
    images, removed = [], []
    for descriptor in document.get('manifests', []):
        platform = descriptor.get('platform', {})
        if platform == {'architecture': 'amd64', 'os': 'linux'}:
            images.append(descriptor)
        elif (platform == {'architecture': 'unknown', 'os': 'unknown'} and
              descriptor.get('annotations', {}).get('vnd.docker.reference.type') == 'attestation-manifest'):
            removed.append(descriptor['digest'])
        else:
            raise ValueError('Unexpected image platform; refusing to drop it')
    if len(images) != 1 or images[0].get('mediaType') != MANIFEST:
        raise ValueError('Expected exactly one Linux amd64 image manifest')
    if any(d.get('annotations', {}).get('vnd.docker.reference.digest') != images[0]['digest']
           for d in document.get('manifests', []) if d['digest'] in removed):
        raise ValueError('Attestation does not refer to the retained image')
    result = {'schemaVersion': 2, 'mediaType': INDEX, 'manifests': images}
    return json.dumps(result, separators=(',', ':')).encode(), removed


class Registry:
    def __init__(self, username, token):
        credentials = base64.b64encode((username + ':' + token).encode()).decode()
        params = urllib.parse.urlencode({'scope': 'repository:' + IMAGE + ':pull,push', 'service': 'ghcr.io'})
        request = urllib.request.Request('https://ghcr.io/token?' + params,
                                         headers={'Authorization': 'Basic ' + credentials})
        with urllib.request.urlopen(request, timeout=60) as response:
            self.token = json.load(response)['token']

    def manifest(self, reference, data=None):
        headers = {'Authorization': 'Bearer ' + self.token, 'Accept': INDEX + ', ' + MANIFEST}
        if data is not None:
            headers['Content-Type'] = INDEX
        request = urllib.request.Request('https://ghcr.io/v2/' + IMAGE + '/manifests/' + reference,
                                         headers=headers, data=data, method='PUT' if data is not None else 'GET')
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                result = response.read()
                return result, response.headers.get('Docker-Content-Digest', digest(result))
        except urllib.error.HTTPError as error:
            raise RuntimeError('Container registry request returned HTTP ' + str(error.code)) from None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--expected-digest', required=True)
    parser.add_argument('--version-tag', required=True)
    parser.add_argument('--output', default='container-privacy.json')
    args = parser.parse_args()
    if not re.fullmatch(r'sha256:[0-9a-f]{64}', args.expected_digest):
        parser.error('Invalid expected image digest')
    if not re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}', args.version_tag) or args.version_tag == 'latest':
        parser.error('Invalid version tag')
    registry = Registry(os.environ['GITHUB_ACTOR'], os.environ['GH_TOKEN'])
    original, original_digest = registry.manifest(args.expected_digest)
    if original_digest != args.expected_digest or digest(original) != args.expected_digest:
        raise RuntimeError('Original index digest does not match')
    cleaned, removed = sanitize_index(json.loads(original))
    cleaned_digest = digest(cleaned)
    image = json.loads(cleaned)['manifests'][0]
    manifest, actual_digest = registry.manifest(image['digest'])
    if actual_digest != image['digest'] or digest(manifest) != image['digest'] or len(manifest) != image['size']:
        raise RuntimeError('Retained image manifest does not match')
    # Verify every tag before changing any. A replay accepts only the exact
    # cleaned digest; concurrent changes to another image always stop the job.
    tags = [args.version_tag, 'latest']
    for tag in tags:
        _, current = registry.manifest(tag)
        if current not in (args.expected_digest, cleaned_digest):
            raise RuntimeError('Image tag changed; refusing to overwrite it')
    for tag in tags:
        _, current = registry.manifest(tag)
        if current == args.expected_digest:
            registry.manifest(tag, cleaned)
        elif current != cleaned_digest:
            raise RuntimeError('Image tag changed before update')
        actual, current = registry.manifest(tag)
        if current != cleaned_digest or actual != cleaned:
            raise RuntimeError('Published image index verification failed')
    report = {'image': 'ghcr.io/' + IMAGE, 'previousIndex': args.expected_digest,
              'index': cleaned_digest, 'preservedImage': image['digest'],
              'removedAttestations': removed, 'tags': tags, 'rebuilt': False}
    with open(args.output, 'w') as output:
        json.dump(report, output, indent=2)
        output.write('\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
