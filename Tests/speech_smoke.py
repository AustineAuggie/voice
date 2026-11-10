"""Run with speech helper, tiny multilingual model and upstream samples/jfk.wav paths."""
import json,struct,subprocess,sys,tempfile,wave,select,math,os
from pathlib import Path
with tempfile.TemporaryDirectory() as d:
    audio=Path(d)/'speech.f32';silence=Path(d)/'silence.f32'
    with wave.open(sys.argv[3]) as w:
        assert w.getframerate()==16000 and w.getsampwidth()==2 and w.getnchannels()==1
        samples=struct.unpack('<'+'h'*w.getnframes(),w.readframes(w.getnframes()))
    audio.write_bytes(struct.pack('<'+'f'*len(samples),*(x/32768 for x in samples)))
    silence.write_bytes(b'\0'*64000)
    p=subprocess.Popen([sys.argv[1],sys.argv[2]],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True)
    assert json.loads(p.stdout.readline())['ready']
    outputs=[]
    for i,path in enumerate([audio,silence,audio,Path(d)/'missing.f32']):
        p.stdin.write(json.dumps({'id':str(i),'audio':str(path),'language':'en','prompt':''})+'\n');p.stdin.flush()
        outputs.append(json.loads(p.stdout.readline()))
    assert 'country' in outputs[0]['text'].lower()
    assert outputs[1]['text']==''
    assert outputs[2]['text']==outputs[0]['text']
    assert 'error' in outputs[3]
    # Cancellation must be acknowledged without unloading the model, and the
    # same process must still transcribe the next real recording correctly.
    cycles=int(os.environ.get("LOCALVOICE_CANCEL_CYCLES", "100"))
    for cycle in range(cycles):
        request_id='cancel-'+str(cycle)
        p.stdin.write(json.dumps({'id':request_id,'audio':str(audio),'language':'en','prompt':''})+'\n')
        p.stdin.write(json.dumps({'cancel':request_id})+'\n');p.stdin.flush()
        assert select.select([p.stdout],[],[],20)[0], 'Cancellation timed out'
        reply=json.loads(p.stdout.readline())
        assert reply['id']==request_id and 'error' in reply, reply
        assert p.poll() is None, 'Cancellation killed the model process'
        if cycle % 25 == 0:
            p.stdin.write(json.dumps({'id':'fresh-'+str(cycle),'audio':str(audio),'language':'en','prompt':''})+'\n');p.stdin.flush()
            assert select.select([p.stdout],[],[],30)[0], 'Fresh inference timed out'
            assert 'country' in json.loads(p.stdout.readline())['text'].lower()
    for language, accuracy in [('auto', False), ('en', True), ('auto', True)]:
        request={'id':f'language-{language}-{accuracy}','audio':str(audio),'language':language,'accuracy':accuracy,'prompt':''}
        p.stdin.write(json.dumps(request)+'\n');p.stdin.flush()
        assert select.select([p.stdout],[],[],120)[0], 'Accuracy/language inference timed out'
        reply=json.loads(p.stdout.readline())
        assert 'country' in reply.get('text','').lower(), reply
        print('Transcribed', language, 'accuracy=', accuracy, ':', reply['text'].strip())
    # Quiet speech embedded in silence must not be rejected by whole-file RMS.
    quiet=Path(d)/'quiet-padded.f32'
    quiet_samples=[x/32768*0.008 for x in samples] + [0.0]*(16000*24-len(samples))
    assert math.sqrt(sum(x*x for x in quiet_samples)/len(quiet_samples)) < 0.001
    quiet.write_bytes(struct.pack('<'+'f'*len(quiet_samples),*quiet_samples))
    p.stdin.write(json.dumps({'id':'quiet-padded','audio':str(quiet),'language':'en','accuracy':True})+'\n');p.stdin.flush()
    assert select.select([p.stdout],[],[],120)[0]
    quiet_result=json.loads(p.stdout.readline())
    assert 'country' in quiet_result.get('text','').lower(),quiet_result
    print('Quiet speech surrounded by silence retained:',quiet_result['text'].strip())
    p.stdin.close();assert p.wait(timeout=20)==0
    print(f'Passed native speech inference, silence, missing-file and {cycles} cancellation/restart checks in one model process.')
