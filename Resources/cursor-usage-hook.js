// Loaded only for MenuTools' `agent about` process. Asks the CLI's own client
// for the same period-usage the interactive /usage command reads.
const Module = require("module");
const original = Module.prototype._compile;

const returnNeedle =
  'return{userEmail:"fulfilled"===l.status?l.value.email??null:null,subscriptionTier:"fulfilled"===r.status?r.value.planInfo?.planName??null:null}';
const returnPatch =
  'return{userEmail:null,subscriptionTier:"fulfilled"===r.status?r.value.planInfo?.planName??null:null,usage:await (async()=>{try{const period=await t.getCurrentPeriodUsage(new n.Dl4({}),{timeoutMs:15000});const plan=period.planUsage||{};const spend=period.spendLimitUsage||{};const limit=Number(spend.individualLimit||0);const used=Number(spend.individualUsed||0);const end=period.billingCycleEnd==null?null:Number(period.billingCycleEnd);return{totalPercentUsed:plan.totalPercentUsed??null,autoPercentUsed:plan.autoPercentUsed??null,apiPercentUsed:plan.apiPercentUsed??null,billingCycleEnd:Number.isFinite(end)?end:null,onDemandPercentUsed:limit>0?Math.max(0,Math.min(100,used/limit*100)):null}}catch(error){return{error:error&&error.code?String(error.code):"unavailable"}}})()}';

const objectNeedle =
  "subscriptionTier:q.subscriptionTier,osPlatform:u,osArch:d,userEmail:q.userEmail";
const objectPatch =
  "subscriptionTier:q.subscriptionTier,usage:q.usage??null,osPlatform:u,osArch:d,userEmail:null";

Module.prototype._compile = function (content, filename) {
  if (typeof content === "string" && content.includes(returnNeedle)) {
    content = content.replace(returnNeedle, returnPatch).replace(objectNeedle, objectPatch);
  }
  return original.call(this, content, filename);
};
