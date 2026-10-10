// User approved only H46SZTDWR5 on 2026-10-10. Never select another certificate.
import {createPrivateKey, sign} from 'node:crypto';
import {pathToFileURL} from 'node:url';
export const approvedId='H46SZTDWR5';
export async function revokeApproved(api){
  const path='/certificates/'+approvedId;
  const before=await api(path);
  if(before.status===404)return {id:approvedId,absent:true,deleteAttempted:false};
  if(before.status!==200)throw Error('Cannot inspect approved certificate: HTTP '+before.status);
  const c=before.body?.data;
  if(c?.id!==approvedId||c.attributes?.certificateType!=='DEVELOPMENT'||c.attributes?.displayName!=='Created via API'||c.attributes?.expirationDate!=='2027-10-09T09:56:42.000+00:00')throw Error('Approved certificate identity changed; no deletion');
  const inventory=await api('/certificates?limit=200');
  if(inventory.status!==200||inventory.body.links?.next)throw Error('Complete signing inventory unavailable; no deletion');
  const preserved=inventory.body.data.filter(x=>x.id!==approvedId).map(x=>x.id);
  let receipt;
  try{receipt=await api(path,'DELETE');}catch{receipt={status:'unknown'};}
  // An uncertain DELETE is never retried. Read actual state instead.
  const after=await api(path);
  if(after.status!==404)throw Error('Revocation unconfirmed; do not retry blindly. DELETE '+receipt.status+'; read '+after.status);
  const remaining=await api('/certificates?limit=200');
  if(remaining.status!==200||remaining.body.links?.next||preserved.some(id=>!remaining.body.data.some(c=>c.id===id)))throw Error('Approved certificate absent; other certificate preservation requires inspection');
  return {id:approvedId,absent:true,deleteAttempted:true,deleteStatus:receipt.status,otherCertificatesPreserved:preserved.length};
}
async function main(){
  const {ASC_KEY_ID:kid,ASC_ISSUER_ID:iss,ASC_KEY_P8:raw}=process.env;
  if(!kid||!iss||!raw)throw Error('Configured signing credentials required');
  const key=createPrivateKey(raw.includes('BEGIN PRIVATE KEY')?raw:Buffer.from(raw,'base64').toString());
  const b64=x=>Buffer.from(JSON.stringify(x)).toString('base64url');
  const now=Math.floor(Date.now()/1000),payload=b64({alg:'ES256',kid,typ:'JWT'})+'.'+b64({iss,iat:now,exp:now+600,aud:'appstoreconnect-v1'});
  const jwt=payload+'.'+sign('sha256',Buffer.from(payload),{key,dsaEncoding:'ieee-p1363'}).toString('base64url');
  const api=async(path,method='GET')=>{const r=await fetch('https://api.appstoreconnect.apple.com/v1'+path,{method,headers:{authorization:'Bearer '+jwt},signal:AbortSignal.timeout(30000)});return {status:r.status,body:r.status===204?null:await r.json().catch(()=>null)};};
  console.log('Approved certificate cleanup: '+JSON.stringify(await revokeApproved(api)));
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href)main().catch(e=>{console.error(e.message);process.exitCode=1;});
