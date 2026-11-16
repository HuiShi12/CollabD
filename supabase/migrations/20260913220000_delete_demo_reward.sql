-- Removes the leftover "Food Souvenir" reward created by the now-deleted
-- "Temporary developer demo" section (reward.dart / reward_viewmodel.dart),
-- per user request — it's fake test data (source_id starts with 'demo_'),
-- not a real gameplay reward.
delete from public.tourist_rewards where source_id like 'demo_%';
