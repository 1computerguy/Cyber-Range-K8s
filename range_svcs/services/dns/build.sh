#!/bin/bash

docker build -t master:5000/bind:latest .
docker push master:5000/bind:latest
docker rmi resystit/bind9:latest