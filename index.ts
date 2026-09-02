// supabase/functions/verify-payment/index.ts
//
// Deploy with:   supabase functions deploy verify-payment
// Secrets needed (supabase secrets set NAME=value):
//   PAYSTACK_SECRET_KEY   — your Paystack secret key (sk_test_... / sk_live_...)
// SUPABASE_URL, SUPABASE_ANON_KEY, and SUPABASE_SERVICE_ROLE_KEY are
// injected automatically into every Edge Function by Supabase — no need to set them.
//
// Called by the client after Paystack's inline popup reports success. This
// function is the only thing allowed to write to `campaigns` and `payouts`
// (RLS blocks direct writes from authenticated users — see schema.sql) so a
// campaign can never exist without a payment that Paystack itself confirms.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const PAYSTACK_SECRET_KEY = Deno.env.get("PAYSTACK_SECRET_KEY")!;
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const MIN_BUDGET = 2000;
const MAX_BUDGET = 100000;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return json({ error: "Missing Authorization header" }, 401);

    let body: { reference?: string; product_id?: string };
    try {
      body = await req.json();
    } catch {
      return json({ error: "Invalid JSON body" }, 400);
    }
    const { reference, product_id } = body;
    if (!reference || !product_id) {
      return json({ error: "reference and product_id are required" }, 400);
    }

    // Identify the caller from their own JWT — never trust a client-supplied user id.
    const userClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: { user }, error: userErr } = await userClient.auth.getUser();
    if (userErr || !user) return json({ error: "Invalid or expired session" }, 401);

    // Service-role client for trusted writes — this is what bypasses RLS.
    const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    // Idempotency: if this exact Paystack reference was already processed
    // (e.g. the client retried, or the callback fired twice), don't double-credit.
    const { data: existing } = await admin
      .from("campaigns")
      .select("id, status, budget")
      .eq("payment_reference", reference)
      .maybeSingle();
    if (existing) {
      return json({ ok: true, already_processed: true, campaign_id: existing.id });
    }

    // Verify the transaction directly with Paystack. This is the step that
    // actually matters — the client's word that "payment succeeded" is never trusted.
    const verifyRes = await fetch(
      `https://api.paystack.co/transaction/verify/${encodeURIComponent(reference)}`,
      { headers: { Authorization: `Bearer ${PAYSTACK_SECRET_KEY}` } },
    );
    const verifyJson = await verifyRes.json();

    if (!verifyRes.ok || !verifyJson?.status || verifyJson.data?.status !== "success") {
      return json({ error: "Payment could not be verified" }, 402);
    }

    const paidKobo = Number(verifyJson.data.amount);
    const paidNaira = paidKobo / 100;
    const payerEmail: string | undefined = verifyJson.data.customer?.email;

    if (payerEmail && user.email && payerEmail.toLowerCase() !== user.email.toLowerCase()) {
      return json({ error: "Payment email does not match the logged-in user" }, 400);
    }

    if (!Number.isFinite(paidNaira) || paidNaira < MIN_BUDGET || paidNaira > MAX_BUDGET) {
      return json({ error: "Paid amount is outside the allowed range" }, 400);
    }

    // Load the product so interest is computed from the DB's rate, not anything the client sent.
    const { data: product, error: productErr } = await admin
      .from("products")
      .select("id, earning_type, fixed_rate, status")
      .eq("id", product_id)
      .single();

    if (productErr || !product) return json({ error: "Product not found" }, 404);

    const budget = paidNaira;

    const { data: campaign, error: campaignErr } = await admin
      .from("campaigns")
      .insert({
        earner_id: user.id,
        product_id: product.id,
        status: "active",
        budget,
        payment_reference: reference,
      })
      .select()
      .single();

    if (campaignErr) {
      // Unique violation on payment_reference = a concurrent duplicate request; treat as already processed.
      if ((campaignErr as { code?: string }).code === "23505") {
        return json({ ok: true, already_processed: true });
      }
      throw campaignErr;
    }

    let payout = null;
    if (product.earning_type === "fixed") {
      const rate = Number(product.fixed_rate) || 0;
      const interest = Math.round((budget * rate) / 100);
      const total = budget + interest;

      const { data: payoutRow, error: payoutErr } = await admin
        .from("payouts")
        .insert({
          user_id: user.id,
          amount: total,
          status: "pending",
          reference,
        })
        .select()
        .single();

      if (payoutErr) throw payoutErr;
      payout = payoutRow;
    }

    return json({ ok: true, campaign, payout });
  } catch (err) {
    console.error(err);
    return json({ error: (err as Error).message || "Unexpected error" }, 500);
  }
});
