#!/usr/bin/python3
"""RustDesk OSS protokolüyle salt geçici NAT/UDP/relay denetimi; gerçek cihaza bağlanmaz."""
import argparse,json,socket,time,uuid

def vi(n):
 out=bytearray()
 while n>127:out.append((n&127)|128);n>>=7
 out.append(n);return bytes(out)
def field(n,b):return vi(n*8+2)+vi(len(b))+b

def frame(b):
 for n,maxn in [(1,0x3f),(2,0x3fff),(3,0x3fffff),(4,0x3fffffff)]:
  if len(b)<=maxn:return ((len(b)<<2)|(n-1)).to_bytes(n,'little')+b
 raise ValueError('large')
def recv_exact(s,n):
 out=b''
 while len(out)<n:
  data=s.recv(n-len(out))
  if not data:raise ValueError('EOF')
  out+=data
 return out

def recv_frame(s):
 first=recv_exact(s,1);head=first+recv_exact(s,(first[0]&3));n=int.from_bytes(head,'little')>>2
 return recv_exact(s,n)
def varint(b,p=0):
 n=0;shift=0
 while True:
  v=b[p];p+=1;n|=(v&127)<<shift
  if v<128:return n,p
  shift+=7

def parse(b):
 p=0;out={}
 while p<len(b):
  k,p=varint(b,p)
  if k&7==2:
   n,p=varint(b,p);v=b[p:p+n];p+=n
  elif k&7==0:v,p=varint(b,p)
  else:raise ValueError('wire')
  out[k>>3]=v
 return out

def run(host,key):
 results=[]
 for port in [21115,21116]:
  with socket.create_connection((host,port),8) as s:
   s.settimeout(8);s.sendall(frame(field(20,b'')));reply=parse(recv_frame(s));nat=parse(reply[21]);assert nat[1]>0
  results.append({'test':'tcp-nat-protocol','port':port,'ok':True})
 with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as s:
  s.settimeout(8);probe_id='bakim-network-probe-'+uuid.uuid4().hex
  s.sendto(field(6,field(1,probe_id.encode())),(host,21116));data,src=s.recvfrom(1024)
  assert parse(parse(data)[7])[2]==1
 results.append({'test':'udp-register-response-no-persistent-device','port':21116,'ok':True})
 pairing='bakim-network-probe-'+uuid.uuid4().hex
 request=frame(field(18,field(1,b'bakim-probe')+field(2,pairing.encode())+field(6,key.encode())))
 with socket.create_connection((host,21117),8) as a,socket.create_connection((host,21117),8) as b:
  a.settimeout(8);b.settimeout(8);a.sendall(request);time.sleep(.1);b.sendall(request);time.sleep(.15)
  msg=b'Bakim.TR Yardim relay verification '+uuid.uuid4().hex.encode();a.sendall(msg);assert recv_exact(b,len(msg))==msg
  reply=b'relay-response';b.sendall(reply);assert recv_exact(a,len(reply))==reply
 results.append({'test':'relay-pair-bidirectional','port':21117,'ok':True})
 return results
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--host',default='95.9.36.60');p.add_argument('--key',default='v15Oj1NdzRE32xyZRKLlk2sfrP8AOLxx5ZxEV3JqYvM=');p.add_argument('--output');a=p.parse_args()
 result={'ok':True,'host':a.host,'sourceContext':'caller-must-document-local-or-external','checks':run(a.host,a.key)}
 rendered=json.dumps(result,indent=2)
 if a.output:open(a.output,'w').write(rendered+'\n')
 print(rendered)
