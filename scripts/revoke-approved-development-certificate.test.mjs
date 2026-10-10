import {test} from 'node:test';
import assert from 'node:assert/strict';
import {approvedId,revokeApproved} from './revoke-approved-development-certificate.mjs';
const cert={id:approvedId,attributes:{certificateType:'DEVELOPMENT',displayName:'Created via API',expirationDate:'2027-10-09T09:56:42.000+00:00'}};
for(const unknown of [false,true])test('exact approved certificate only; uncertain delete='+unknown,async()=>{
 let removed=false,deletes=[];
 const api=async(path,method='GET')=>{
  if(method==='DELETE'){deletes.push(path);removed=true;if(unknown)throw Error('connection lost');return {status:204};}
  if(path.includes('?'))return {status:200,body:{data:[...(removed?[]:[cert]),{id:'distribution-preserved'}]}};
  return removed?{status:404}:{status:200,body:{data:cert}};
 };
 const r=await revokeApproved(api);assert.equal(r.absent,true);assert.equal(r.otherCertificatesPreserved,1);assert.deepEqual(deletes,['/certificates/'+approvedId]);
});
test('already absent needs no delete',async()=>{let calls=0;assert.equal((await revokeApproved(async(p,m)=>{calls++;assert.equal(m,undefined);return {status:404};})).deleteAttempted,false);assert.equal(calls,1);});
for(const attributes of [{...cert.attributes,certificateType:'DISTRIBUTION'},{...cert.attributes,displayName:'Personal certificate'},{...cert.attributes,expirationDate:'different'}])test('changed identity refuses deletion '+JSON.stringify(attributes),async()=>{
 await assert.rejects(revokeApproved(async(p,m)=>{assert.equal(m,undefined);return {status:200,body:{data:{...cert,attributes}}};}),/identity changed/);
});
test('unknown outcome is not replayed',async()=>{let n=0;await assert.rejects(revokeApproved(async(p,m)=>{
 if(m==='DELETE'){n++;throw Error('timeout');}
 if(p.includes('?'))return {status:200,body:{data:[cert]}};
 return {status:200,body:{data:cert}};
}),/unconfirmed/);assert.equal(n,1);});
