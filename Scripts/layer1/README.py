#!/usr/bin/env python3
"""Layer 1 CLI decoders: print {"text": ..., "words": [{word,start,end}]}.

One script per model family so model_commands.json stays declarative. Every
script takes the audio path as argv[1], prints exactly one JSON object to
stdout (progress noise goes to stderr or is suppressed), and never raises.
"""
