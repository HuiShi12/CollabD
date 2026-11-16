-- UC-05 — VisitProofRepository now records how close the tourist was (real GPS
-- distance to the mystery place) when they verified.
alter table public.visit_proofs
  add column if not exists distance_meter int;
