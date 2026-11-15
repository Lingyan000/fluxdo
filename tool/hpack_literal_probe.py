"""只处理回环实验中的 H2；记录原始头块，不是通用 HTTP 服务器。"""
import argparse,datetime,json,pathlib,socket,ssl,subprocess,threading,time
from cryptography import x509
from cryptography.x509.oid import NameOID
from cryptography.hazmat.primitives import hashes,serialization
from cryptography.hazmat.primitives.asymmetric import ec
p=argparse.ArgumentParser();p.add_argument('browser');p.add_argument('output',type=pathlib.Path);p.add_argument('--external',action='store_true');p.add_argument('--sequence',action='store_true');p.add_argument('--field-size',type=int,default=600);a=p.parse_args();a.output.mkdir(parents=True)
if not 0<=a.field_size<=8192:p.error('field-size must be between 0 and 8192')
key=ec.generate_private_key(ec.SECP256R1());name=x509.Name([x509.NameAttribute(NameOID.COMMON_NAME,'localhost')]);now=datetime.datetime.now(datetime.timezone.utc)
cert=x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key()).serial_number(x509.random_serial_number()).not_valid_before(now-datetime.timedelta(days=1)).not_valid_after(now+datetime.timedelta(days=1)).add_extension(x509.SubjectAlternativeName([x509.DNSName('localhost')]),False).sign(key,hashes.SHA256())
(a.output/'cert.pem').write_bytes(cert.public_bytes(serialization.Encoding.PEM));(a.output/'key.pem').write_bytes(key.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption()));(a.output/'key.pem').chmod(0o600)
context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);context.load_cert_chain(a.output/'cert.pem',a.output/'key.pem');context.set_alpn_protocols(['h2'])
listener=socket.socket();listener.bind(('127.0.0.1',0));listener.listen();port=listener.getsockname()[1];listener.settimeout(1);done=threading.Event();records=[];errors=[]
def frame(kind,flags,stream,payload=b''):return len(payload).to_bytes(3,'big')+bytes([kind,flags])+stream.to_bytes(4,'big')+payload
def readn(c,n):
 b=b''
 while len(b)<n:
  more=c.recv(n-len(b))
  if not more:raise EOFError()
  b+=more
 return b
page=b"<!doctype html><script>fetch('/literal',{headers:{'x-probe':'~~~~','x-tie':'PATCH','x-compress':'aaaaaaaa'}}).then(()=>document.title='fluxdo-probe-done')</script>"
if a.sequence:
 page=b"""<!doctype html><script>(async()=>{
 for(let i=0;i<14;i++){
  let h={'x-repeat':'unchanged','x-probe':'~~~~','x-tie':'PATCH','x-change':String(i%2),'if-none-match':'lab-etag'};
  if(i>=3&&i<11)h['x-fill']='a'.repeat(FIELD_SIZE)+i;
  await fetch('/hpack/'+i,{headers:h,cache:'no-store'});
 }
 await fetch('/hpack/done',{headers:{'x-end-marker':'~~~~END~~~~'}});
 document.title='fluxdo-probe-done';
})()</script>""".replace(b'FIELD_SIZE',str(a.field_size).encode())
def serve(raw,connection):
 try:
  with context.wrap_socket(raw,server_side=True) as c:
   c.settimeout(15)
   if readn(c,24)!=b'PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n':raise ValueError('missing H2 preface')
   c.sendall(frame(4,0,0));blocks={};seen=0
   while not done.is_set():
    h=readn(c,9);size=int.from_bytes(h[:3],'big');kind,flags=h[3:5];stream=int.from_bytes(h[5:],'big')&0x7fffffff;body=readn(c,size)
    if kind==4 and not flags&1:c.sendall(frame(4,1,0))
    elif kind==6 and not flags&1:c.sendall(frame(6,1,0,body))
    elif kind in [1,9]:
     if kind==1:
      padding=body[0] if flags&8 else 0;start=(1 if flags&8 else 0)+(5 if flags&32 else 0);body=body[start:len(body)-padding if padding else None];blocks[stream]=b''
     blocks[stream]+=body
     if flags&4:
      block=blocks.pop(stream);seen+=1;records.append({'connection':connection,'stream':stream,'header_block_hex':block.hex(),'literal_tilde':b'\x04~~~~' in block,'literal_tie':b'\x05PATCH' in block})
      response=page if seen==1 else b'ok'
      # :status=200 与字面 content-type=text/html；明确结束响应体。
      c.sendall(frame(1,4,stream,b'\x88\x0f\x10\x09text/html')+frame(0,1,stream,response))
      if (a.sequence and b'~~~~END~~~~' in block) or (not a.sequence and seen>1):done.set()
 except (OSError,EOFError) as e:errors.append(type(e).__name__+':'+str(e))
def accept():
 connection=0
 while not done.is_set():
  try:c,_=listener.accept()
  except socket.timeout:continue
  except OSError:break
  threading.Thread(target=serve,args=(c,connection),daemon=True).start();connection+=1
threading.Thread(target=accept,daemon=True).start()
args=[a.browser]
if not a.external:args+=['--headless','--no-sandbox','--disable-dev-shm-usage','--ignore-certificate-errors','--disable-background-networking','--remote-debugging-port=0','--user-data-dir='+str(a.output/'profile')]
args+=['https://localhost:'+str(port)+'/fluxdo-probe']
with (a.output/'browser.stdout').open('w') as out,(a.output/'browser.stderr').open('w') as err:
 child=subprocess.Popen(args,stdout=out,stderr=err)
 completed=done.wait(20);time.sleep(.2);child.terminate()
 try:child.wait(timeout=3)
 except subprocess.TimeoutExpired:child.kill();child.wait()
listener.close();result={'completed':completed,'headers':records,'errors':errors,'not_verified':['dynamic_table_policy','full_hpack_equivalence']};(a.output/'capture.json').write_text(json.dumps(result,indent=2));print(json.dumps({'completed':completed,'literal_tilde':any(r['literal_tilde'] for r in records),'literal_tie':any(r['literal_tie'] for r in records)}))
raise SystemExit(0 if completed else 1)
