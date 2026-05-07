
import argparse

import asyncio

import hashlib

import json

import os

import re

import shutil

import subprocess

import urllib.request

from pathlib import Path

from mcp import ClientSession, StdioServerParameters

from mcp.client.stdio import stdio_client

import uuid

from .ScoutConfigAndConstants import *


def prompt_terms(prompt):
    return [token for token in re.findall('[a-z0-9_./-]+', prompt.lower()) if ((len(token) > 2) and (token not in STOP_WORDS))]


def packet_mode_for_prompt(prompt):
    lowered = prompt.lower()
    if re.search('\\b(review|regression|bugs?|buggy|do we have bugs|problems?|risk|risks)\\b', lowered):
        return 'review'
    if re.search('\\b(implement|implementation|add|create|modify|update|fix|build)\\b', lowered):
        return 'implementation'
    if re.search('\\b(change|changed|changes|changet|modified|recent|last|what changed|diff|git|status)\\b', lowered):
        return 'changes'
    if re.search('\\b(debug|crash|error|exception|fail|failing|failure|log|traceback|not work|broken|diagnose|slow|latency)\\b', lowered):
        return 'debug'
    return 'direct'


def classify_prompt_intent(prompt):
    lowered = prompt.lower()
    packet_mode = packet_mode_for_prompt(prompt)
    score = 0
    matches = []
    for keyword in DEBUG_KEYWORDS:
        if (keyword in lowered):
            score += 2
            matches.append(keyword)
    if re.search('\\b(line|stack|trace|traceback|stderr|stdout)\\b', lowered):
        score += 2
    if re.search('\\.(py|sh|swift|js|ts|log|json|toml|yaml|yml|plist)\\b', lowered):
        score += 2
    if ('/' in prompt):
        score += 1
    if (packet_mode != 'direct'):
        score += 2
    needs_gather = (score >= 2)
    if needs_gather:
        reason = (f"Prompt looks like a debugging/investigation request ({', '.join(matches[:3])})." if matches else 'Prompt references code, logs, or failure symptoms that benefit from local evidence.')
    else:
        reason = 'No evidence gathered; packet contains only the prompt.'
    return {'needs_gather': needs_gather, 'reason': reason, 'packet_mode': packet_mode, 'confidence': min(1.0, (0.45 + (score * 0.08)))}
