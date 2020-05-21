#!/bin/bash

docker run --volume="$PWD:/srv/jekyll" --publish-all -itd jekyll/minimal:$JEKYLL_VERSION jekyll serve
