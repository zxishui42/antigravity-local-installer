import { RELEASED_ROUTES } from "./routes.js";
import { PACKAGES } from "./packages.js";
import { DELIVERY_ZIPS } from "./delivery.js";
import { SETUP_HTML, COMPLETE_HTML } from "./ui-pages.js";

const PRODUCT_KEY = "antigravity_local_setup_pack";
const CREATE_PATH = "/v1/actions/checkout/create-session";
const CREATE_URL = "https://api.waffo.ai" + CREATE_PATH;
const encoder = new TextEncoder();
function jsonResponse(data,status=200){return new Response(JSON.stringify(data),{status,headers:{"Content-Type":"application/json; charset=utf-8","Cache-Control":"no-store","X-Content-Type-Options":"nosniff"}});}
function textResponse(body,type,status=200){return new Response(body,{status,headers:{"Content-Type":type,"Cache-Control":"no-cache","X-Content-Type-Options":"nosniff"}});}
function num(v){return v===null||v===undefined||v===""?null:Number(v);}
function nowIso(){return new Date().toISOString();}
function b64(bytes){let s="";const a=bytes instanceof Uint8Array?bytes:new Uint8Array(bytes);for(let i=0;i<a.length;i+=0x8000)s+=String.fromCharCode(...a.subarray(i,i+0x8000));return btoa(s);}
function unb64(s){const raw=atob(String(s).replace(/\s+/g,""));const out=new Uint8Array(raw.length);for(let i=0;i<raw.length;i++)out[i]=raw.charCodeAt(i);return out;}
function b64url(bytes){return b64(bytes).replace(/\+/g,"-").replace(/\//g,"_").replace(/=+$/g,"");}
function unb64url(s){let x=String(s).replace(/-/g,"+").replace(/_/g,"/");while(x.length%4)x+="=";return unb64(x);}
function pemBody(v){return String(v||"").replace(/-----BEGIN [^-]+-----/g,"").replace(/-----END [^-]+-----/g,"").replace(/\s+/g,"");}
function publicAvailability(r){const o={status:r.status||"temporarily_unsupported"};if(r.platform)o.platform=r.platform;if(r.requiredRamGb!==undefined)o.requiredRamGb=r.requiredRamGb;if(r.detectedRamGb!==undefined)o.detectedRamGb=r.detectedRamGb;return o;}

function resolveInstaller(p){
 const runtime=p.runtime||"automatic", memory=num(p.memoryGb), sys=num(p.systemRamGb);
 const row=RELEASED_ROUTES.find(r=>r[0]===p.os&&r[1]===p.graphics&&r[2]===p.hardwareId&&(r[3]===null||num(r[3])===memory)&&r[4]===runtime);
 if(!row)return {status:"no_released_installer"};
 const need=num(row[6]);if(need!==null){const have=sys!==null?sys:memory;if(have===null)return {status:"need_system_ram",requiredRamGb:need};if(have<need)return {status:"not_enough_ram",requiredRamGb:need,detectedRamGb:have};}
 const profile=row[5],pkg=PACKAGES[profile];if(!pkg||!DELIVERY_ZIPS[profile])throw new Error("release_mapping_error");
 return {status:"installer_available",profileId:profile,sha256:pkg.sha256,platform:pkg.platform};
}
async function importPrivateKey(v){return crypto.subtle.importKey("pkcs8",unb64(pemBody(v)),{name:"RSASSA-PKCS1-v1_5",hash:"SHA-256"},false,["sign"]);}
async function importPublicKey(v){return crypto.subtle.importKey("spki",unb64(pemBody(v)),{name:"RSASSA-PKCS1-v1_5",hash:"SHA-256"},false,["verify"]);}
async function waffoSession(env,orderId,resolved,email){
 const body={productId:env.WAFFO_PRODUCT_ID,currency:env.WAFFO_CURRENCY||"USD",successUrl:`${env.PUBLIC_BASE_URL}/install/complete/?order=${encodeURIComponent(orderId)}`,expiresInSeconds:3600,orderMerchantExternalId:orderId,metadata:{productKey:PRODUCT_KEY,priceUsd:env.WAFFO_EXPECTED_SUBTOTAL||"5.60",profileId:resolved.profileId,installerSha256:resolved.sha256},language:"en"};if(email)body.buyerEmail=email;
 const raw=JSON.stringify(body),digest=await crypto.subtle.digest("SHA-256",encoder.encode(raw)),ts=String(Math.floor(Date.now()/1000)),canonical=`POST\n${CREATE_PATH}\n${ts}\n${b64(digest)}`;
 const sig=await crypto.subtle.sign("RSASSA-PKCS1-v1_5",await importPrivateKey(env.WAFFO_PRIVATE_KEY),encoder.encode(canonical));
 const response=await fetch(CREATE_URL,{method:"POST",headers:{"Content-Type":"application/json","X-Merchant-Id":env.WAFFO_MERCHANT_ID,"X-Timestamp":ts,"X-Signature":b64(sig),"X-Idempotency-Key":`antigravity_${orderId}`},body:raw});
 const data=await response.json().catch(()=>({}));if(!response.ok)throw new Error(`waffo_${response.status}`);const s=data.data||{};if(!s.checkoutUrl||!s.sessionId)throw new Error("waffo_invalid_response");return s;
}
async function hmacKey(secret){return crypto.subtle.importKey("raw",encoder.encode(secret),{name:"HMAC",hash:"SHA-256"},false,["sign","verify"]);}
async function makeToken(secret,order,profile,exp){const msg=`${order}|${profile}|${exp}`,sig=await crypto.subtle.sign("HMAC",await hmacKey(secret),encoder.encode(msg));return `v1.${exp}.${b64url(sig)}`;}
async function verifyToken(secret,token,order,profile){const p=String(token||"").split(".");if(p.length!==3||p[0]!=="v1")return false;const exp=Number(p[1]);if(!Number.isFinite(exp)||exp<Math.floor(Date.now()/1000))return false;try{return await crypto.subtle.verify("HMAC",await hmacKey(secret),unb64url(p[2]),encoder.encode(`${order}|${profile}|${exp}`));}catch{return false;}}
function parseSig(h){const o={};for(const q of String(h||"").split(",")){const i=q.indexOf("=");if(i>0)o[q.slice(0,i).trim()]=q.slice(i+1).trim();}return o;}
async function verifyWebhook(env,raw,h){if(!env.WAFFO_WEBHOOK_PUBLIC_KEY)return false;const s=parseSig(h);if(!s.t||!s.v1)return false;const t=Number(s.t);if(!Number.isFinite(t)||Math.abs(Date.now()-t)>45*60*1000)return false;try{return await crypto.subtle.verify("RSASSA-PKCS1-v1_5",await importPublicKey(env.WAFFO_WEBHOOK_PUBLIC_KEY),unb64(s.v1),encoder.encode(`${s.t}.${raw}`));}catch{return false;}}

function apiCatalog(){return jsonResponse({os:[...new Set(RELEASED_ROUTES.map(r=>r[0]))],routes:RELEASED_ROUTES.map(r=>[r[0],r[1],r[2],r[3],r[4]])});}
async function apiAvailability(req){const p=await req.json().catch(()=>null);if(!p)return jsonResponse({detail:"invalid_json"},400);return jsonResponse(publicAvailability(resolveInstaller(p)));}
async function apiCheckout(req,env){
 const p=await req.json().catch(()=>null);if(!p)return jsonResponse({detail:"invalid_json"},400);const r=resolveInstaller(p);if(r.status!=="installer_available")return jsonResponse({detail:publicAvailability(r)},409);
 const id="AGL_"+crypto.randomUUID().replace(/-/g,""),n=nowIso();await env.ORDERS_DB.prepare(`INSERT INTO orders(order_id,created_at,updated_at,status,email,os,graphics,hardware_id,memory_gb,system_ram_gb,runtime,profile_id,installer_sha256,price_usd,currency) VALUES(?,?,?,'pending',?,?,?,?,?,?,?,?,?,?,?)`).bind(id,n,n,p.email||null,p.os,p.graphics,p.hardwareId,num(p.memoryGb),num(p.systemRamGb),p.runtime||"automatic",r.profileId,r.sha256,env.WAFFO_EXPECTED_SUBTOTAL||"5.60",env.WAFFO_CURRENCY||"USD").run();
 try{const s=await waffoSession(env,id,r,p.email||null);await env.ORDERS_DB.prepare("UPDATE orders SET waffo_session_id=?,waffo_checkout_url=?,updated_at=? WHERE order_id=?").bind(s.sessionId,s.checkoutUrl,nowIso(),id).run();return jsonResponse({orderId:id,checkoutUrl:s.checkoutUrl});}catch(e){console.error(e);await env.ORDERS_DB.prepare("UPDATE orders SET status='checkout_failed',updated_at=? WHERE order_id=?").bind(nowIso(),id).run();return jsonResponse({detail:"waffo_checkout_failed"},502);}
}
async function apiOrder(env,id){const r=await env.ORDERS_DB.prepare("SELECT * FROM orders WHERE order_id=?").bind(id).first();if(!r)return jsonResponse({detail:"order_not_found"},404);const o={orderId:r.order_id,status:r.status,platform:String(r.profile_id).startsWith("macos-")?"macos":"windows"};if(r.status==="paid"){const exp=Math.floor(Date.now()/1000)+Number(env.DOWNLOAD_TOKEN_TTL_SECONDS||3600);o.downloadUrl=`${env.PUBLIC_BASE_URL}/api/download/${encodeURIComponent(r.order_id)}?token=${encodeURIComponent(await makeToken(env.DELIVERY_SIGNING_SECRET,r.order_id,r.profile_id,exp))}`;o.downloadExpiresAt=exp;}return jsonResponse(o);}
async function apiDownload(env,id,token){const r=await env.ORDERS_DB.prepare("SELECT * FROM orders WHERE order_id=?").bind(id).first();if(!r||r.status!=="paid")return jsonResponse({detail:"paid_order_required"},403);if(!(await verifyToken(env.DELIVERY_SIGNING_SECRET,token,r.order_id,r.profile_id)))return jsonResponse({detail:"invalid_or_expired_download_token"},403);const z=DELIVERY_ZIPS[r.profile_id];if(!z)return jsonResponse({detail:"delivery_missing"},500);return new Response(unb64(z),{headers:{"Content-Type":"application/zip","Content-Disposition":'attachment; filename="AntigravityLocalSetupPack.zip"',"Cache-Control":"private, no-store","X-Content-Type-Options":"nosniff"}});}
async function apiWebhook(req,env){
 const raw=await req.text();if(!(await verifyWebhook(env,raw,req.headers.get("X-Waffo-Signature"))))return new Response("Invalid signature",{status:401});let e;try{e=JSON.parse(raw);}catch{return new Response("Invalid JSON",{status:400});}if(e.mode!=="prod")return new Response("OK");const type=e.eventType||"",eventId=e.eventId||e.id||"";if(!type||!eventId)return new Response("OK");const seen=await env.ORDERS_DB.prepare("SELECT 1 AS x FROM webhook_events WHERE event_type=? AND event_id=?").bind(type,eventId).first();if(seen)return new Response("OK");const d=e.data||{};
 if(type==="order.completed"){const id=d.orderMerchantExternalId,row=id?await env.ORDERS_DB.prepare("SELECT * FROM orders WHERE order_id=?").bind(id).first():null;if(row&&row.status!=="refunded"&&d.orderStatus==="completed"&&d.paymentStatus==="succeeded"&&d.currency===row.currency){const md=d.orderMetadata||{},subtotal=String((d.listPrice&&d.listPrice.subtotal)!=null?d.listPrice.subtotal:(d.subtotal!=null?d.subtotal:""));const meta=md.productKey===PRODUCT_KEY&&md.profileId===row.profile_id&&md.installerSha256===row.installer_sha256&&String(md.priceUsd)===String(row.price_usd),price=subtotal===""||Number(subtotal)===Number(row.price_usd),product=!d.productName||d.productName===(env.WAFFO_PRODUCT_NAME||"Antigravity Local Setup Pack");if(meta&&price&&product)await env.ORDERS_DB.prepare("UPDATE orders SET status='paid',updated_at=?,paid_at=?,email=COALESCE(?,email),waffo_order_id=?,waffo_payment_id=? WHERE order_id=?").bind(nowIso(),nowIso(),d.buyerEmail||null,d.orderId||null,d.paymentId||null,row.order_id).run();}}
 else if(type==="refund.succeeded"){if(d.orderMerchantExternalId)await env.ORDERS_DB.prepare("UPDATE orders SET status='refunded',updated_at=?,refunded_at=? WHERE order_id=?").bind(nowIso(),nowIso(),d.orderMerchantExternalId).run();}
 await env.ORDERS_DB.prepare("INSERT OR IGNORE INTO webhook_events(event_type,event_id,received_at) VALUES(?,?,?)").bind(type,eventId,nowIso()).run();return new Response("OK");
}
async function proxyOld(req){const u=new URL(req.url);const target=new URL(u.pathname+u.search,"https://www.antigravitylocalmodels.com");const h=new Headers(req.headers);h.delete("host");const res=await fetch(new Request(target,{method:req.method,headers:h,redirect:"follow"}));const ct=res.headers.get("content-type")||"";if(req.method==="GET"&&ct.includes("text/html")){let html=await res.text();const cta='<a class="cta-fixed" href="/setup-pack/" style="position:fixed;right:22px;bottom:22px;z-index:2147483647;background:#000;color:#fff;text-decoration:none;padding:14px 18px;border:1px solid #000;font:600 14px/1.2 Arial,sans-serif;box-shadow:0 4px 18px rgba(0,0,0,.16)">Quick Install · $5.60</a>';html=html.replace(/<\/body>/i,cta+'</body>');const hh=new Headers(res.headers);hh.delete("content-length");hh.set("cache-control","no-cache");return new Response(html,{status:res.status,headers:hh})}return res;}

export default {async fetch(req,env,ctx){const u=new URL(req.url),p=u.pathname;try{
 if(p==="/setup-pack/"||p==="/setup-pack")return textResponse(SETUP_HTML,"text/html; charset=utf-8");
 if(p==="/install/complete/"||p==="/install/complete")return textResponse(COMPLETE_HTML,"text/html; charset=utf-8");
 if(req.method==="GET"&&p==="/api/catalog")return apiCatalog();
 if(req.method==="POST"&&p==="/api/availability/check")return apiAvailability(req);
 if(req.method==="POST"&&p==="/api/checkout/create")return apiCheckout(req,env);
 if(req.method==="POST"&&p==="/api/payment/webhook/waffo")return apiWebhook(req,env);
 let m;if(req.method==="GET"&&(m=p.match(/^\/api\/orders\/([^/]+)$/)))return apiOrder(env,decodeURIComponent(m[1]));
 if(req.method==="GET"&&(m=p.match(/^\/api\/download\/([^/]+)$/)))return apiDownload(env,decodeURIComponent(m[1]),u.searchParams.get("token")||"");
 if(p.startsWith("/api/"))return jsonResponse({detail:"not_found"},404);
 return proxyOld(req);
 }catch(e){console.error(e);return jsonResponse({detail:"internal_error"},500);}}};
