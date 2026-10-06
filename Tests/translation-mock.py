from http.server import BaseHTTPRequestHandler,HTTPServer
import json
class Handler(BaseHTTPRequestHandler):
 def log_message(self,*args):print("Fixture:",*args,flush=True)
 def do_POST(self):
  data=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
  good=self.path=='/v1/chat/completions' and self.headers.get('Authorization')=='Bearer fixture-key' and data['model']=='fixture-model' and data['messages'][1]['content']=='Hello\n    world'
  body=json.dumps({'choices':[{'message':{'content':'你好\n    世界'}}]}).encode()
  self.send_response(200 if good else 400);self.send_header('Content-Type','application/json');self.end_headers();self.wfile.write(body)
server=HTTPServer(('127.0.0.1',18767),Handler)
print('Fixture listening on',server.server_address,flush=True)
server.serve_forever()
