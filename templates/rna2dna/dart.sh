#!/usr/bin/env bash

dart -i ${ref} \
  -f ${reads[0]} \
  -f2 ${reads[1]} \
  -t ${task.cpus} \
  ${ALIGN_PARAMS} \
  -o out.sam