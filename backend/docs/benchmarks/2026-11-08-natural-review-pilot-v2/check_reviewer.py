"""Two development probes of the final production reviewer; no draft-model call."""
import json,time
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[3]))
from google import genai
from google.genai import types
from app.config import settings
from app.schemas import FeedbackReview
from app.services import suggestions
from tools import benchmark_suggestions as bench
folder=Path('docs/benchmarks/2026-11-08-natural-review-pilot-v2')
first=folder.parent/'2026-11-08-natural-review-pilot'
manifest=json.loads((folder/'manifest.json').read_text())
assert manifest['review_prompt_sha256']==bench.digest(suggestions.REVIEW_INSTRUCTION)
cases={case['id']:case for case in json.loads((folder/'cases.json').read_text())}
initial=bench.read_rows(first/'generations.jsonl')
current=bench.read_rows(folder/'generations.jsonl')
assert len(initial)==len(current)==5
bad_strong=next(row['message'] for row in initial if row['case_id']=='pilot-strong')
probes=[('two-actions','pilot-strong',bad_strong,
         'Two distinct maintenance behaviors: acceleration and braking.'),
        ('invented-progress','pilot-declining',
         'Your speed grade improved from 91 to a perfect 100 across your recorded trips. Check your speed against posted limits on your next drive.',
         'Speed calendar-half means actually decline from 91 to 73, and no report has a speed grade of 100.')]
path=folder/'reviewer_checks.jsonl'
existing=bench.read_rows(path)
seen={row['attempt_id'] for row in existing}
limiter=bench.RateLimiter(initial+current+existing)
with genai.Client(api_key=settings.gemini_api_key.strip(),vertexai=False,
    http_options=types.HttpOptions(timeout=int(settings.gemini_timeout_seconds*1000),
        retry_options=types.HttpRetryOptions(attempts=1))) as client:
    for probe_id,case_id,draft,issue in probes:
        if probe_id in seen: continue
        payload=json.dumps({'history':cases[case_id]['history'],'draft':draft},ensure_ascii=False,allow_nan=False)
        stamp,reserve=limiter.acquire(suggestions.REVIEW_INSTRUCTION+payload,4096)
        row={'attempt_id':probe_id,'case_id':case_id,'draft':draft,'expected_issue':issue,
             'started_unix':stamp,'token_reservation':reserve,'stage':'reviewer_control'}
        started=time.perf_counter()
        try:
            response=client.models.generate_content(model=settings.gemini_model.strip(),contents=payload,
                config=types.GenerateContentConfig(system_instruction=suggestions.REVIEW_INSTRUCTION,
                    response_mime_type='application/json',response_json_schema=FeedbackReview.model_json_schema(),
                    max_output_tokens=4096,candidate_count=1,temperature=1.0))
            row['provider_response']=bench.response_record(response)
            if not response.candidates or response.candidates[0].finish_reason!=types.FinishReason.STOP:
                raise ValueError('Incomplete response')
            review=FeedbackReview.model_validate_json(response.text)
            row.update(ok=True,review=review.model_dump())
        except Exception as exc:
            row.update(ok=False,error={'type':type(exc).__name__})
        row['elapsed_seconds']=round(time.perf_counter()-started,4)
        bench.append_row(path,row)
        print(json.dumps({key:row.get(key) for key in ['attempt_id','ok','review','error']},ensure_ascii=False),flush=True)
