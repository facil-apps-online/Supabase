-- 20251110000004_add_index_to_notifications.sql
-- This index is created to speed up the fetching of notifications for a specific user,
-- ordered by creation date, which is a common operation for notification bells.
CREATE INDEX CONCURRENTLY notifications_user_id_created_at_idx ON public.notifications (user_id, created_at DESC);
