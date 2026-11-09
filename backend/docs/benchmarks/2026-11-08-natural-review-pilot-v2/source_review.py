"""Explicit source-grounded Codex AI judgments of this exact five-output development run."""
import hashlib,json
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[3]))
from tools import benchmark_suggestions as bench
folder=Path('docs/benchmarks/2026-11-08-natural-review-pilot-v2')
rows=bench.read_rows(folder/'generations.jsonl')
assert len(rows)==5 and all(row['ok'] for row in rows)
reviews={
'pilot-declining': {
 'claims': [('Keeping these trip records gives you a useful starting point to work from as you review your driving patterns.', 'Six dated reports with positive driving time span 35 days. Every category declines from 91 to 73 across the calendar halves. Encouragement concerns logging, not fabricated improvement.')],
 'motivation': 'Keeping these trip records gives you a useful starting point to work from as you review your driving patterns.',
 'action': 'Check your speed periodically to stay aligned with limits.',
 'action_evidence': 'One speed-monitoring behavior, relevant to the repeatedly declining speed grades. The advice does not claim a known speed-limit value or past cause.',
},
'pilot-strong': {
 'claims': [('Your recorded trips consistently maintain high scores across all evaluated categories.', 'All six positive-duration regular trips have every measured grade equal to 96; the record spans 35 days.')],
 'motivation': 'Your recorded trips consistently maintain high scores across all evaluated categories.',
 'action': 'Keep applying steady pressure to the accelerator pedal as you begin moving from a stop.',
 'action_evidence': 'One accelerator-control maintenance behavior, connected to acceleration grades of 96 throughout the sample. This imperative is advice, not a separate factual assertion that the data measured a particular past pedal technique.',
},
'pilot-mixed': {
 'claims': [('Your speed grades have steadily improved across your recorded trips.', 'The eight regular positive-duration trips have speed grades 54, 60, 66, 72, 78, 84, 90, 96; earlier/recent means are 63 and 87. Braking moves in the opposite direction, from 87.5 to 67.5.')],
 'motivation': 'Your speed grades have steadily improved across your recorded trips.',
 'action': 'Begin slowing earlier when approaching a stop.',
 'action_evidence': 'One concrete braking-timing behavior relevant to the repeated braking decline. No invented cause, road condition, or second action.',
},
'pilot-modes': {
 'claims': [('Your speed grades have remained consistently high across your recorded trips.', 'Speed is 94 on all six positive-duration trips, including three regular and three pocket trips. No mode-driven overall-grade improvement is claimed.')],
 'motivation': 'Your speed grades have remained consistently high across your recorded trips.',
 'action': 'Begin leaving more space between your vehicle and the cars ahead of you on future drives.',
 'action_evidence': 'One following-gap behavior. The three regular trips have measured following-distance grades of 55. The subsequent pocket trips do not measure this category, and the message does not claim they improved.',
},
'pilot-zero': {
 'claims': [('Keeping these trip records gives you a useful starting point to work from', 'Six dated reports are stored; encouragement concerns recording effort, not actual driving quality.'), ('your recorded trips currently show zero driving time.', 'Every saved trip duration is zero; measuredByMode has no positive-duration reports despite stored grades of 93.')],
 'motivation': 'Keeping these trip records gives you a useful starting point to work from, even though your recorded trips currently show zero driving time.',
 'action': 'Please check that your next saved trip includes active driving time so your future records can accurately capture your habits.',
 'action_evidence': 'One specific duration check addresses the missing exposure data. The purpose clause adds no second behavior or guarantee of safety.',
},
}
audits=[]
for row in rows:
    item=reviews[row['case_id']]
    for quote,evidence in item['claims']: assert quote in row['message']
    assert item['motivation'] in row['message'] and item['action'] in row['message']
    evidence=' '.join(evidence for quote,evidence in item['claims'])
    assessment={
      'factualClaims':[{'quote':quote,'evidence':support,'verdict':'supported'} for quote,support in item['claims']],
      'motivationalObservations':[{'quote':item['motivation'],'evidence':evidence,'supported':True}],
      'actionableSuggestions':[{'quote':item['action'],'evidence':item['action_evidence'],'supported':True}],
      'longTermRelevant':True,'longTermEvidence':evidence+' The recommendation addresses the multi-trip history, not only the latest trip.',
      'plainText':True,'notes':'Codex AI review against the exact frozen synthetic reports and existing benchmark rubric; no human validation. These are reused development cases, not a held-out accuracy estimate.',
    }
    bench.Assessment.model_validate(assessment)
    audits.append({'attempt_id':row['attempt_id'],'reviewer':'Codex AI source review',
      'reason':'Explicit claim and semantic-element review of final free-form text against saved reports/reference facts; production approve/correct decisions are not treated as quality labels.',
      'generation_sha256':hashlib.sha256(row['message'].encode()).hexdigest(),'assessment':assessment})
(folder/'audit.jsonl').write_text(''.join(json.dumps(item,ensure_ascii=False)+'\n' for item in audits))
bench.report(folder,json.loads((folder/'manifest.json').read_text()),json.loads((folder/'cases.json').read_text()))
