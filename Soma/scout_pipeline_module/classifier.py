





import re








from .config import *


TERM_ALIASES = {
    'quiet': {'cooldown', 'mute', 'muted', 'nudge', 'policy', 'schedule', 'settings', 'silence'},
    'hours': {'calendar', 'cooldown', 'end', 'hour', 'minute', 'minutes', 'scheduler', 'start'},
    'hour': {'calendar', 'cooldown', 'end', 'minute', 'minutes', 'scheduler', 'start'},
    'midnight': {'calendar', 'cross', 'date', 'day', 'end', 'minute', 'overnight', 'start'},
    'interval': {'end', 'range', 'schedule', 'start'},
    'schedule': {'scheduler', 'nudge', 'timer'},
    'scheduler': {'schedule', 'nudge', 'timer'},
    'bubble': {'nudge', 'speak', 'speech'},
    'bug': {'error', 'exception', 'fail', 'failure', 'runtime'},
    'bugs': {'error', 'exception', 'fail', 'failure', 'runtime'},
    'settings': {'config', 'configuration', 'preferences'},
    'test': {'fixture', 'fixtures', 'spec', 'tests'},
    'tests': {'fixture', 'fixtures', 'spec', 'test'},
}


def split_identifier_terms(value):
    spaced = re.sub(r'([a-z0-9])([A-Z])', r'\1 \2', str(value or ''))
    spaced = re.sub(r'([A-Z]+)([A-Z][a-z])', r'\1 \2', spaced)
    pieces = re.split(r'[^A-Za-z0-9]+', spaced)
    return [piece.lower() for piece in pieces if len(piece) > 2 and piece.lower() not in STOP_WORDS]


def prompt_terms(prompt):
    terms = []
    for token in re.findall('[A-Za-z0-9_./-]+', prompt or ''):
        lowered = token.lower()
        if ((len(lowered) > 2) and (lowered not in STOP_WORDS)):
            terms.append(lowered)
        terms.extend(split_identifier_terms(token))
    return list(dict.fromkeys(terms))


def expanded_prompt_terms(prompt):
    terms = prompt_terms(prompt)
    expanded = list(terms)
    term_set = set(terms)
    for term in terms:
        expanded.extend(sorted(TERM_ALIASES.get(term, set())))
    if ('quiet' in term_set and (('hours' in term_set) or ('hour' in term_set))):
        expanded.extend(['behavior', 'cooldown', 'fixture', 'fixtures', 'policy', 'scheduler', 'settings'])
    if ('midnight' in term_set and (('quiet' in term_set) or ('hours' in term_set) or ('hour' in term_set))):
        expanded.extend(['cross', 'day', 'end', 'minute', 'overnight', 'start'])
    return list(dict.fromkeys(term for term in expanded if len(term) > 2 and term not in STOP_WORDS))


def packet_mode_for_prompt(prompt):
    lowered = prompt.lower()
    if re.search('\\b(read[- ]only|investigate|investigation|analyze|analysis|inspect|diagnose)\\b', lowered):
        if re.search('\\b(debug|crash|error|exception|fail|failing|failure|log|traceback|not work|broken|diagnose|slow|latency)\\b', lowered):
            return 'debug'
        return 'review'
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
