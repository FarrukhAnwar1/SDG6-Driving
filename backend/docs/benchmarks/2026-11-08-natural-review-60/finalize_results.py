"""Finalize the full regression only after all saved messages have explicit AI reviews."""
from collections import Counter
from pathlib import Path
import csv,hashlib,json,math,statistics,sys
BACKEND=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(BACKEND))
from tools import benchmark_suggestions as bench
OUT=BACKEND/'docs/benchmarks/2026-11-08-natural-review-60'

def latency(rows):
    values=sorted(r['elapsed_seconds'] for r in rows if r['ok'])
    return {'completed_suggestions':len(values),'mean':round(statistics.mean(values),3) if values else None,
            'median':round(statistics.median(values),3) if values else None,
            'p95_nearest_rank':values[math.ceil(.95*len(values))-1] if values else None}

def finalize():
    manifest=json.loads((OUT/'manifest.json').read_text())
    cases=json.loads((OUT/'cases.json').read_text())
    rows=bench.read_rows(OUT/'generations.jsonl')
    audits=bench.read_rows(OUT/'audit.jsonl')
    assert len(rows)==60 and len(cases)==20
    assert Counter(r['case_id'] for r in rows)==Counter({case['id']:3 for case in cases})
    assert {r['attempt_id'] for r in audits}=={r['attempt_id'] for r in rows if r['ok']}
    for audit in audits:
        row=next(r for r in rows if r['attempt_id']==audit['attempt_id'])
        assert audit['generation_sha256']==hashlib.sha256(row['message'].encode()).hexdigest()
        assessment=bench.Assessment.model_validate(audit['assessment'])
        for element in [*assessment.factualClaims,*assessment.motivationalObservations,*assessment.actionableSuggestions]:
            assert element.quote in row['message'], (audit['attempt_id'],element.quote)
    for name,expected in manifest['source_sha256'].items():
        assert hashlib.sha256((OUT/'source_snapshot'/name).read_bytes()).hexdigest()==expected
        assert hashlib.sha256((BACKEND/name).read_bytes()).hexdigest()==expected
    bench.report(OUT,manifest,cases)
    summary=json.loads((OUT/'summary.json').read_text())
    quota=json.loads((OUT/'quota_observations.json').read_text())
    scored=json.loads((OUT/'scored_responses.json').read_text())
    failures=[]
    for row in rows:
        if row['ok']: continue
        errors=[call['error'] for call in row['provider_calls'] if call.get('error')]
        category='provider_or_transport_failure' if errors else 'response_validation_failure'
        if not errors and row.get('review_decision')=='approve':
            last=row['provider_responses'][-1]
            text=''.join(part.get('text','') for part in last.get('candidates',[{}])[0].get('content',{}).get('parts',[]))
            try:
                if json.loads(text).get('message')!=row.get('draft_message'):
                    category='approval_changed_draft'
            except (ValueError,AttributeError): pass
        failures.append({'attempt_id':row['attempt_id'],'category':category,'error':row['error'],'provider_errors':errors,'calls':len(row['provider_calls'])})
    validation={'logical_attempts':60,'histories':20,'repetitions':3,'completed_suggestions':sum(r['ok'] for r in rows),
      'source_reviewed_final_messages':len(audits),'all_requirements_passes':summary['passes']['all_pass'],
      'api_calls':quota['total_calls'],'production_call_cap':120,'separate_gemini_grading_calls':0,'judge_calibration_calls':0,
      'max_calls_in_rolling_minute':quota['max_calls_in_rolling_minute'],
      'max_reserved_tokens_in_rolling_minute':quota['max_reserved_tokens_in_rolling_minute'],
      'quota_errors':sum(call.get('error',{}).get('provider_status')==429 for r in rows for call in r['provider_calls']),
      'completed_suggestion_latency_seconds':latency(rows),'generation_failures':failures,
      'failure_categories':dict(Counter(f['category'] for f in failures)),
      'semantic_failures':[{'attempt_id':r['attempt_id'],'scores':r['scores'],'assessment':r['assessment']} for r in scored if r['scores'] and not r['scores']['all_pass']],
      'source_snapshot_hashes_match':True,'human_reviewers':0,'exact_text_review_reuses':sum('reused_exact_message_review_from' in a for a in audits),'review_method':'Explicit Codex AI source and semantic review; no separate Gemini scorer and no human validation',
      'limitations':['Same 20 development histories; repetitions are correlated, not an unseen-data accuracy estimate.','AI review and qualitative strength judgments need independent human validation.','Completion latency excludes injected quota waits, database work and Flutter/network end-to-end time.']}
    with (OUT/'review.csv').open(newline='') as stream:
        human_rows=list(csv.DictReader(stream))
    assert len(human_rows)==60 and all(not row[key] for row in human_rows for key in ('human_grounded','human_motivation','human_action','human_notes'))
    validation['human_review_columns_empty']=True
    assert quota['total_calls']<=120 and quota['max_calls_in_rolling_minute']<=8
    assert quota['max_reserved_tokens_in_rolling_minute']<=150000
    (OUT/'validation.json').write_text(json.dumps(validation,indent=2,ensure_ascii=False)+'\n')
    runs=[]
    for label,folder in [('Original free-form','2026-11-08-gemini-suggestions'),('Fixed-choice pipeline','2026-11-08-gemini-suggestions-improved-60'),('Natural draft + AI review',OUT.name)]:
        directory=OUT.parent/folder
        s=json.loads((directory/'summary.json').read_text())
        data=bench.read_rows(directory/'generations.jsonl')
        previous_cases=json.loads((directory/'cases.json').read_text())
        assert {c['id']:c['history']['reports'] for c in previous_cases}=={c['id']:c['history']['reports'] for c in cases}
        runs.append({'label':label,'folder':folder,'attempts':len(data),'completed':sum(r['ok'] for r in data),
                     'scored':s['scored_responses'],'passes':s['passes'],'completed_latency_seconds':latency(data)})
    (OUT/'comparison.json').write_text(json.dumps({'same_raw_histories':True,'runs':runs,'human_reviewers':0,
       'note':'Pipeline and review methods differ; all figures are descriptive AI-reviewed regression results, not a causal model-only comparison.'},indent=2)+'\n')
    lines=['# Matched 60-attempt regression comparison','','All three runs use the same 20 synthetic histories, three attempts each. Scores are AI source review; no human validation.','',
      '| Measure | Original free-form | Fixed-choice pipeline | Natural draft + AI review |','| --- | ---: | ---: | ---: |']
    lines.append('| Completed suggestions | '+' | '.join(f"{r['completed']}/60" for r in runs)+' |')
    for title,key in [('No unsupported factual claims','grounded'),('Exactly one supported motivational observation','motivation'),('Exactly one supported concrete action','action'),('Both coaching requirements','coaching_compliance'),('Long-term relevance','long_term'),('Format','format')]:
        lines.append('| '+title+' | '+' | '.join(f"{r['passes'][key]}/{r['scored']} scored" for r in runs)+' |')
    lines.append('| All requirements, including successful completion | '+' | '.join(f"{r['passes']['all_pass']}/60" for r in runs)+' |')
    lines.append('| Mean completed-suggestion latency | '+' | '.join(f"{r['completed_latency_seconds']['mean']}s" for r in runs)+' |')
    lines+=['',f"Current run: {quota['total_calls']} production API calls; no separate Gemini grading or calibration calls. All failed attempts remain in the denominator.",
      f"Completion latency includes both current production calls and SDK setup, excluding quota sleeps, database work, and Flutter/network end-to-end time. Its denominator is {validation['completed_suggestions']} completed messages; the harness's general generation-latency field also includes failed attempts.",
      '', 'The fixed-choice system restricts prose to prewritten verified sentences. The current system writes freely and adds a same-model reviewer/corrector; review can miss errors. These are pipeline changes, not a controlled model-only experiment.',
      '', 'The histories were used during development and the three repetitions are correlated. Semantic classifications, especially qualitative praise, are Codex AI judgments and require independent human review. The blank human-review columns and claim-by-claim evidence remain available. See validation.json for every failure.']
    (OUT/'COMPARISON.md').write_text('\n'.join(lines)+'\n')
    intro=f"Completion-time note: the {validation['completed_suggestions']} completed suggestions averaged {validation['completed_suggestion_latency_seconds']['mean']}s for draft plus review. The general generation-latency field below includes failed attempts too. See [comparison](COMPARISON.md), [validation](validation.json), and [review method](REVIEW_METHOD.md).\n\n"
    readme=OUT/'README.md'
    readme.write_text(intro+readme.read_text().rstrip()+'\n')
    print(json.dumps({'completed':validation['completed_suggestions'],'passes':validation['all_requirements_passes'],'calls':validation['api_calls'],'latency':validation['completed_suggestion_latency_seconds'],'failure_categories':validation['failure_categories']},indent=2))

if __name__=='__main__': finalize()
