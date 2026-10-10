// Read-only Apple signing inventory. Never prints credentials or deletes assets.
import {createPrivateKey, sign, X509Certificate} from 'node:crypto';
const {ASC_KEY_ID:kid,ASC_ISSUER_ID:iss,ASC_KEY_P8:raw}=process.env;
if(!kid||!iss||!raw)throw Error('Signing inventory needs configured App Store Connect credentials.');
const key=createPrivateKey(raw.includes('BEGIN PRIVATE KEY')?raw:Buffer.from(raw,'base64').toString());
const b64=x=>Buffer.from(JSON.stringify(x)).toString('base64url');
const now=Math.floor(Date.now()/1000),payload=b64({alg:'ES256',kid,typ:'JWT'})+'.'+b64({iss,iat:now,exp:now+600,aud:'appstoreconnect-v1'});
const jwt=payload+'.'+sign('sha256',Buffer.from(payload),{key,dsaEncoding:'ieee-p1363'}).toString('base64url');
async function get(path){const r=await fetch('https://api.appstoreconnect.apple.com/v1'+path,{headers:{authorization:'Bearer '+jwt},signal:AbortSignal.timeout(30000)});if(!r.ok)throw Error('Inventory HTTP '+r.status);return r.json();}
const result=await get('/certificates?limit=200');
const certificates=result.data.map(c=>{
 let issued=null;try{issued=new X509Certificate(Buffer.from(c.attributes.certificateContent,'base64')).validFrom;}catch{}
 return {id:c.id,type:c.attributes.certificateType,name:c.attributes.displayName,expires:c.attributes.expirationDate,issued};
});
console.log(JSON.stringify({readOnly:true,certificates,hasMore:!!result.links?.next},null,2));
