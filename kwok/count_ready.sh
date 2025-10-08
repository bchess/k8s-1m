#!/usr/bin/env bash
time kc get nodes | tee nodes.txt | awk '{print $2}' | sort | uniq -c
