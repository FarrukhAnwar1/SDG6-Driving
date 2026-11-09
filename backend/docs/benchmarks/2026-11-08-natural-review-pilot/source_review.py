"""Explicit Codex AI review of the five saved first-pilot outputs, not a model judge."""
import hashlib,json
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[3]))
from tools import benchmark_suggestions as bench
folder=Path('docs/benchmarks/2026-11-08-natural-review-pilot')
rows=bench.read_rows(folder/'generations.jsonl')
assert len(rows)==5 and all(row['ok'] for row in rows)
reviews={
'pilot-declining': {
 'claim': 'Keeping these trip records gives you a useful starting point to work from as you review your driving habits over time.',
 'evidence': 'Six dated, positive-duration reports span 35 days. Every category declines from 91 to 73 between the calendar halves. Logging encouragement makes no claim of improvement.',
 'actions': [('Begin checking your speedometer more frequently to monitor your pace on future trips.', 'One concrete monitoring behavior. Speed grades decline from 91 to 73 across three trips per period.')],
},
'pilot-strong': {
 'claim': 'Your recorded trips show consistent high-level performance across all evaluated driving categories over the past several weeks.',
 'evidence': 'Six positive-duration regular reports span 35 days; every measured category is 96 on every report. This describes consistent strength, not improvement or guaranteed safety.',
 'actions': [('Keep maintaining steady acceleration', 'A concrete maintenance behavior supported by consistently strong acceleration grades of 96.'), ('smooth braking habits on every upcoming trip.', 'Braking is a second independently executable maintenance behavior; braking grades are also 96. The conjunction does not make these one action.')],
},
'pilot-mixed': {
 'claim': 'Your speed grades have shown steady improvement across your recorded trips.',
 'evidence': 'Eight positive-duration regular trips have speed grades 54, 60, 66, 72, 78, 84, 90, 96; calendar-half means increase from 63 to 87. Braking declines from 87.5 to 67.5.',
 'actions': [('Begin slowing earlier when approaching a stop to smooth out your braking on future drives.', 'One braking behavior with a purpose clause, relevant to the repeated braking decline; no invented past cause.')],
},
'pilot-modes': {
 'claim': 'Your driving records show consistent strength in maintaining steady speed and smooth acceleration across your trips.',
 'evidence': 'All six positive-duration reports have speed and acceleration grades of 94, across three regular and three pocket trips. This is one cohesive strength observation, not a claim that mode-driven overall grades improved.',
 'actions': [('For your next drive, try increasing the space between your vehicle and the car ahead when following in traffic.', 'One following-gap behavior. The three measured regular trips have following-distance grades of 55; pocket grades are null, not claimed to improve.')],
},
'pilot-zero': {
 'claim': 'Thank you for consistently keeping your trip records updated.',
 'evidence': 'Six dated reports are stored, but every report has zero driving duration. Encouragement concerns logging only and does not treat stored grades of 93 as demonstrated driving habits.',
 'actions': [('Please check that your next saved trip includes recorded driving time.', 'One specific data-quality check directly addresses zero duration in every report.')],
},
}
audits=[]
for row in rows:
    item=reviews[row['case_id']]
    assert item['claim'] in row['message']
    assessment={
        'factualClaims':[{'quote':item['claim'],'evidence':item['evidence'],'verdict':'supported'}],
        'motivationalObservations':[{'quote':item['claim'],'evidence':item['evidence'],'supported':True}],
        'actionableSuggestions':[{'quote':quote,'evidence':evidence,'supported':True} for quote,evidence in item['actions']],
        'longTermRelevant':True,'longTermEvidence':item['evidence'], 'plainText':True,
        'notes':'Codex AI semantic review of the exact saved message and frozen synthetic records; no human or separate Gemini evaluator. Strong-history output fails the exactly-one-action requirement.' if row['case_id']=='pilot-strong' else 'Codex AI semantic review of the exact saved message and frozen synthetic records; no human or separate Gemini evaluator.',
    }
    bench.Assessment.model_validate(assessment)
    audits.append({'attempt_id':row['attempt_id'],'reviewer':'Codex AI source review',
        'reason':'Explicit review of final free-form text against frozen synthetic reports, numerical reference facts, and the benchmark rubric. Production approvals are not used as quality labels.',
        'generation_sha256':hashlib.sha256(row['message'].encode()).hexdigest(),'assessment':assessment})
(folder/'audit.jsonl').write_text(''.join(json.dumps(item,ensure_ascii=False)+'\n' for item in audits))
bench.report(folder,json.loads((folder/'manifest.json').read_text()),json.loads((folder/'cases.json').read_text()))
