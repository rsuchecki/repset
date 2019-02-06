FROM ubuntu:16.04

RUN apt-get update --fix-missing \
    && apt-get install -y wget curl pbzip2 gawk \
    && apt-get autoremove -y \
    && apt-get clean