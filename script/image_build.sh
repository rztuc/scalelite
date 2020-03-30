#!/bin/bash

docker build --build-arg BUILD_NUMBER=1 -t scalelite-local:v1-nginx --target=nginx .
docker build --build-arg BUILD_NUMBER=1 -t scalelite-local:v1-api --target=api .
docker build --build-arg BUILD_NUMBER=1 -t scalelite-local:v1-poller --target=poller .
docker build --build-arg BUILD_NUMBER=1 -t scalelite-local:v1-recording-importer --target=recording-importer .
