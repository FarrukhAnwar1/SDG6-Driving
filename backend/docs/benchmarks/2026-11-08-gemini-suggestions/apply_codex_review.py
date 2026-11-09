"""Apply the recorded Codex AI review decisions for this specific saved run."""
import copy
import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(root))
from tools.benchmark_suggestions import Assessment, score_response

out = Path(__file__).resolve().parent
generations = [json.loads(line) for line in (out / 'generations.jsonl').read_text().splitlines()]
judgments = {row['attempt_id']: row for row in
             (json.loads(line) for line in (out / 'judgments.jsonl').read_text().splitlines())}
assert len(generations) == len(judgments) == 60
assert all(row['ok'] for row in generations) and all(row['ok'] for row in judgments.values())

case_checks = {
    1: 'Checked the 60-to-90 grade sequence, earlier/recent means of 66/84, and repeated speed events.',
    2: 'Checked all grades declining from 92 to 64, zero recorded smoothness events, and speed rates rising from 3 to 7 per hour.',
    3: 'Checked six identical 98-point reports with zero events; maintenance recommendations must still obey the one-action rule.',
    4: 'Checked speed 50, braking 45, other grades 65, overall 59.17, and recurring braking events.',
    5: 'Checked speed rising 60-to-88 (period means 66/82), braking falling 88-to-53, and increasing braking events.',
    6: 'Checked measured following scores 0-to-50 and overall period means 76.67/81.67; zero was not treated as null.',
    7: 'Checked 90-point core grades, focus scores 45-to-55, and 24 focus events; prospective advice does not establish a past cause.',
    8: 'Checked navigation focus is null, speed is 65, other measured scores are 90, and speed events recur.',
    9: 'Checked pocket turning 88 and braking 66; focus/following are unmeasured; coordinated braking details are one maneuver.',
    10: 'Checked core scores remain 92 despite the regular-to-pocket mode change; focus/following weaknesses are in regular trips only.',
    11: 'Checked all grades stay 75 and speed rate stays four per hour despite lower raw counts and duration; no improvement is established.',
    12: 'Checked speed grades 70-to-80, event rates four-to-three per hour, and constant 90-point other categories.',
    13: 'Checked six 90-point saved reports, zero driving time/distance, and undefined event rates; actual habits are not demonstrated.',
    14: 'Checked six 75-point reports, gaps between observed weeks, speed rate two per hour, and zero other recorded events.',
    15: 'Checked seven speed scores of 85 followed by one of 40, eight trips with speed events, and constant 90-point other categories.',
    16: 'Checked six dated 90-point reports plus an undated 10-point report; full-sample average is 78.57 and the undated report cannot be ordered.',
    17: 'Checked following scores are null, speed/focus are 90, braking is 70, and 18 braking events are recorded.',
    18: 'Checked overall 85, acceleration/turning 90, repeated speed/braking events, and overlapping durations; no unique-time claims were made.',
    19: 'Checked speed 70, other categories 90, overall 86.67, speed rate six per hour, and that the road-name instructions were not followed.',
    20: 'Checked six dated reports over exactly 28 days, other categories 90, speed 60-to-80, and recent speed average 76.',
}

# These are explicit semantic review decisions, not a text-matching classifier.
vague = {
    '02-declining/r1': 'Reducing violations is an outcome, without a concrete driver behavior or technique.',
    '04-weak/r1': 'Focusing on smoother braking practices names the improvement goal without a concrete technique.',
    '04-weak/r2': 'Focusing on smoother braking practices names the improvement goal without a concrete technique.',
    '05-mixed/r1': 'Applying the same steady care to braking does not specify an observable action.',
    '05-mixed/r3': 'Maintaining smoother braking states the goal without a timing, pressure, spacing, or monitoring behavior.',
    '09-pocket/r2': 'Smoother deceleration and braking names an outcome without specifying a maneuver or technique.',
    '11-less-exposure/r1': 'Managing speed more carefully names the target without a concrete monitoring or control behavior.',
    '14-missing-weeks/r1': 'Smoothing out pace names a goal without a concrete monitoring or control behavior.',
    '15-latest-outlier/r2': 'Smoothing out speed control names a goal without a concrete monitoring or control behavior.',
    '17-legacy-null/r2': 'Working on smoother braking habits names a category/goal rather than an action or technique.',
    '18-overlap/r2': 'Maintaining smoother braking habits names a goal without specifying a driver behavior.',
    '18-overlap/r3': 'Focusing on smoother braking habits names a goal without specifying a driver behavior.',
    '20-minimum-history/r1': 'Smoothing out speed control names a goal without a concrete monitoring or control behavior.',
}

audits = []
for row in generations:
    attempt_id = row['attempt_id']
    original = judgments[attempt_id]['assessment']
    a = copy.deepcopy(original)
    reasons = [case_checks[int(row['case_id'].split('-')[0])]]
    message = row['message']
    if attempt_id in vague:
        assert len(a['actionableSuggestions']) == 1
        a['actionableSuggestions'][0]['supported'] = False
        a['actionableSuggestions'][0]['evidence'] = (
            'The target category is evidenced, but the candidate fails the strict practical-action criterion: ' + vague[attempt_id])
        reasons.append('Corrected an overly generous actionability label. ' + vague[attempt_id])

    if attempt_id in {'02-declining/r1', '02-declining/r3'}:
        first_sentence = message.split('. ', 1)[0] + '.'
        a['motivationalObservations'] = [{
            'quote': first_sentence, 'supported': False,
            'evidence': 'The praise includes invented perfect smoothness scores. Braking, acceleration, and turning decline from 92 to 64; true trip recording does not validate the whole praise sentence.',
        }]
        reasons.append('Corrected motivation: the evaluator selected only the true tracking subphrase and omitted the invented perfect scores from the same praise sentence.')

    if attempt_id == '03-strong/r1':
        a['actionableSuggestions'] = [
            {'quote': 'maintaining these smooth acceleration', 'supported': True, 'evidence': 'Acceleration scores are consistently 98.'},
            {'quote': 'braking', 'supported': True, 'evidence': 'Braking scores are consistently 98; braking is independently executable from accelerating.'},
            {'quote': 'focus patterns', 'supported': True, 'evidence': 'Focus scores are consistently 98; attention is another independent behavior.'},
        ]
        reasons.append('Split acceleration, braking, and focus maintenance into three independent recommendation candidates, consistent with the evaluator treatment of similar messages.')
    if attempt_id == '03-strong/r3':
        a['actionableSuggestions'] = [
            {'quote': 'maintaining your smooth acceleration', 'supported': True, 'evidence': 'Acceleration scores are consistently 98.'},
            {'quote': 'braking habits', 'supported': True, 'evidence': 'Braking scores are consistently 98; braking is independently executable from acceleration.'},
        ]
        reasons.append('Split acceleration and braking maintenance into two independently executable actions.')

    if attempt_id in {'10-mode-switch/r2', '10-mode-switch/r3'}:
        a['actionableSuggestions'] = [
            {'quote': 'keep an eye on your focus', 'supported': True, 'evidence': 'Regular trips have focus grade 45 and focus violations.'},
            {'quote': 'following distance', 'supported': True, 'evidence': 'Regular trips have following grade 60 and following violations; monitoring this is independent of monitoring attention.'},
        ]
        reasons.append('Split advice about attention and following distance into two independent recommendation candidates.')

    if attempt_id == '09-pocket/r3':
        a['actionableSuggestions'] = [{
            'quote': 'try anticipating stops earlier and applying gentle, gradual pressure on Example Avenue.',
            'supported': True,
            'evidence': 'This describes the timing and pressure of one coordinated braking maneuver, tied to repeated braking events and braking score 66. Treat consistently with the earlier/gradual braking instruction in 05-mixed/r2.',
        }]
        reasons.append('Combined timing and pressure details into one coordinated braking suggestion; these describe a single maneuver.')

    if attempt_id in {'15-latest-outlier/r1', '15-latest-outlier/r2', '15-latest-outlier/r3'}:
        a['longTermRelevant'] = True
        a['longTermEvidence'] = 'Speed events occur in all eight reports, not just the last; the message praises steady 90-point other grades and recommends speed control without claiming a sustained multiweek decline.'
        reasons.append('Corrected long-term relevance: a single latest score setback does not invalidate advice about speed events recurring in all eight trips; the response never claims a sustained decline.')
    if attempt_id in {'20-minimum-history/r2', '20-minimum-history/r3'}:
        a['longTermRelevant'] = True
        a['longTermEvidence'] = 'The message compares a recent average with grades across six trips spanning 28 days, which meets the required scope; it makes no lifetime claim.'
        reasons.append('Corrected a false lifetime-data requirement introduced by the evaluator, not by the coach.')
    if attempt_id == '16-undated/r3':
        a['longTermRelevant'] = True
        a['longTermEvidence'] = 'The response explicitly restricts its 90-point observation to dated weekly reports, and separately references recorded speed events. It does not claim the seven-report overall average is 90 or assign the undated report to a calendar period.'
        reasons.append('Corrected a false attribution: the evaluator treated an explicitly dated-report observation as a claim about all seven reports.')
    if attempt_id == '16-undated/r1':
        for claim in a['factualClaims']:
            if 'earlier tracking' in claim['quote']:
                claim['verdict'] = 'unverifiable'
                claim['evidence'] = 'The events belong to an undated report. Earlier tracking ambiguously assigns chronology that the report-date history does not establish; conservatively flagged under the no-temporal-claims rule for undated reports.'
        a['longTermRelevant'] = False
        a['longTermEvidence'] = 'The dated-grade observation is supported, but earlier tracking ambiguously places the undated report in time; this conservative wording judgment needs human review.'
        reasons.append('Resolved inconsistent factual/temporal labels conservatively: earlier tracking for an undated report is ambiguous, not established chronology.')

    if attempt_id == '11-less-exposure/r3':
        a['factualClaims'].append({
            'quote': 'this steady progress', 'verdict': 'contradicted',
            'evidence': 'Every grade stays 75 and the speed event rate stays four per driving hour; lower raw counts reflect less driving, not progress.',
        })
        a['motivationalObservations'] = [{
            'quote': message.split('. ', 1)[0] + '. To keep building on this steady progress',
            'supported': False,
            'evidence': 'The consistency observation is supported, but the attached progress claim is not; grades and exposure-adjusted rates are unchanged.',
        }]
        reasons.append('Added a missed factual claim: steady progress falsely implies improvement in a history with constant grades and unchanged event rates.')
    if attempt_id == '13-zero-exposure/r3':
        a['factualClaims'].append({
            'quote': 'demonstrating reliable driving habits', 'verdict': 'unverifiable',
            'evidence': 'All six saved reports have zero driving duration and distance. Stored 90-point grades demonstrate a stored-score pattern, not observed reliable driving habits.',
        })
        for observation in a['motivationalObservations']:
            observation['supported'] = False
            observation['evidence'] = 'The score-consistency fact is supported, but reliable actual driving habits are not established when all driving exposure is zero.'
        reasons.append('Added a missed extrapolation from stored grades to demonstrated actual habits despite zero driving exposure.')
    if attempt_id == '07-focus/r2':
        a['factualClaims'] = [claim for claim in a['factualClaims'] if claim['quote'] != 'try minimizing distractions']
        reasons.append('Removed prospective advice from the factual-claim list; a recommendation does not assert the driver previously experienced distractions or a particular cause.')

    Assessment.model_validate(a)
    audits.append({
        'attempt_id': attempt_id, 'reviewer': 'Codex (AI; not an independent human reviewer)',
        'reviewed_at': datetime.now(timezone.utc).isoformat(),
        'generation_sha256': hashlib.sha256(message.encode()).hexdigest(),
        'changed_assessment': a != original,
        'changed_score': score_response(message, a) != score_response(message, original),
        'reason': ' '.join(reasons), 'assessment': a,
    })

(out / 'audit.jsonl').write_text(''.join(json.dumps(row, ensure_ascii=False) + '\n' for row in audits), encoding='utf-8')
changes = [row for row in audits if row['changed_assessment']]
print('AI-reviewed:', len(audits), 'assessments corrected:', len(changes),
      'metric labels corrected:', sum(row['changed_score'] for row in audits))
