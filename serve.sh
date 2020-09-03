#!/bin/bash

export JEKYLL_VERSION=3.8
docker run --rm --volume="$PWD:/srv/jekyll" -p 4000:4000 --publish-all -it jekyll/minimal:$JEKYLL_VERSION jekyll serve
