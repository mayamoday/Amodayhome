-- =====================================================================
-- Amoday Home: database schema for Supabase
-- Based on DATABASE_SCHEMA.md, adapted for Supabase Auth
-- (users.id = auth.users.id, no password_hash) + Row Level Security
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ---------- Tables ----------

CREATE TABLE households (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name         VARCHAR(100) NOT NULL,
  invite_code  VARCHAR(20) UNIQUE DEFAULT upper(substr(md5(random()::text), 1, 8)),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- User profile. Login and passwords are handled by Supabase Auth (auth.users)
CREATE TABLE users (
  id             UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email          VARCHAR(255) NOT NULL UNIQUE,
  display_name   VARCHAR(100),
  last_login_at  TIMESTAMPTZ,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE household_members (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  household_id  UUID NOT NULL REFERENCES households(id) ON DELETE CASCADE,
  user_id       UUID REFERENCES users(id) ON DELETE SET NULL,
  name          VARCHAR(50) NOT NULL,
  role          VARCHAR(20) NOT NULL DEFAULT 'ילד/ה'
                CHECK (role IN ('אבא', 'אמא', 'ילד/ה', 'אחר')),
  is_admin      BOOLEAN NOT NULL DEFAULT false,
  avatar        VARCHAR(255),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (household_id, user_id)
);

CREATE TABLE categories (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  household_id  UUID REFERENCES households(id) ON DELETE CASCADE,
  name          VARCHAR(50) NOT NULL,
  icon          VARCHAR(50),
  sort_order    SMALLINT NOT NULL DEFAULT 0,
  UNIQUE (household_id, name)
);
CREATE UNIQUE INDEX uq_system_categories ON categories (name) WHERE household_id IS NULL;

CREATE TABLE inventory_items (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  household_id  UUID NOT NULL REFERENCES households(id) ON DELETE CASCADE,
  category_id   UUID NOT NULL REFERENCES categories(id) ON DELETE RESTRICT,
  name          VARCHAR(100) NOT NULL,
  quantity      INTEGER NOT NULL DEFAULT 1 CHECK (quantity >= 0),
  status        VARCHAR(20) NOT NULL DEFAULT 'מלא'
                CHECK (status IN ('מלא', 'חצי', 'כמעט ריק')),
  notes         TEXT,
  created_by    UUID REFERENCES household_members(id) ON DELETE SET NULL,
  updated_by    UUID REFERENCES household_members(id) ON DELETE SET NULL,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_updated  TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (household_id, name)
);
CREATE INDEX idx_inventory_status   ON inventory_items (household_id, status);
CREATE INDEX idx_inventory_category ON inventory_items (household_id, category_id);

CREATE TABLE shopping_list_items (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  household_id        UUID NOT NULL REFERENCES households(id) ON DELETE CASCADE,
  inventory_item_id   UUID REFERENCES inventory_items(id) ON DELETE SET NULL,
  name                VARCHAR(100) NOT NULL,
  requested_quantity  INTEGER NOT NULL DEFAULT 1 CHECK (requested_quantity > 0),
  note                VARCHAR(255),
  added_by            UUID REFERENCES household_members(id) ON DELETE SET NULL,
  added_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  is_completed        BOOLEAN NOT NULL DEFAULT false,
  completed_by        UUID REFERENCES household_members(id) ON DELETE SET NULL,
  completed_at        TIMESTAMPTZ
);
CREATE INDEX idx_shopping_list ON shopping_list_items (household_id, is_completed, added_at DESC);
CREATE INDEX idx_shopping_inv  ON shopping_list_items (inventory_item_id);

CREATE TABLE user_settings (
  user_id                UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  notifications_enabled  BOOLEAN NOT NULL DEFAULT true,
  dark_mode              BOOLEAN NOT NULL DEFAULT false,
  active_household_id    UUID REFERENCES households(id) ON DELETE SET NULL,
  updated_at             TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE inventory_history (
  id                       BIGSERIAL PRIMARY KEY,
  inventory_item_id        UUID NOT NULL REFERENCES inventory_items(id) ON DELETE CASCADE,
  member_id                UUID REFERENCES household_members(id) ON DELETE SET NULL,
  action                   VARCHAR(20) NOT NULL
                           CHECK (action IN ('created', 'updated', 'status_changed', 'restocked', 'deleted')),
  quantity_before          INTEGER,
  quantity_after           INTEGER,
  status_before            VARCHAR(20),
  status_after             VARCHAR(20),
  source_shopping_item_id  UUID REFERENCES shopping_list_items(id) ON DELETE SET NULL,
  created_at               TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_history_item ON inventory_history (inventory_item_id, created_at DESC);

-- System categories
INSERT INTO categories (household_id, name, icon, sort_order) VALUES
  (NULL, 'מקרר',        'kitchen',            1),
  (NULL, 'מזווה',       'shelves',            2),
  (NULL, 'חומרי ניקוי', 'cleaning_services',  3),
  (NULL, 'קפאון',       'ac_unit',            4),
  (NULL, 'כללי',        'category',           5);

-- ---------- Automatic updated_at triggers ----------

CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $fn$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$fn$;

CREATE OR REPLACE FUNCTION set_last_updated() RETURNS trigger
LANGUAGE plpgsql AS $fn$
BEGIN
  NEW.last_updated := now();
  RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_households_updated    BEFORE UPDATE ON households    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_users_updated         BEFORE UPDATE ON users         FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_user_settings_updated BEFORE UPDATE ON user_settings FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_inventory_updated     BEFORE UPDATE ON inventory_items FOR EACH ROW EXECUTE FUNCTION set_last_updated();

-- ---------- Automatic profile + settings on sign-up ----------

CREATE OR REPLACE FUNCTION handle_new_user() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
BEGIN
  INSERT INTO public.users (id, email, display_name)
  VALUES (NEW.id, NEW.email, NEW.raw_user_meta_data->>'display_name');
  INSERT INTO public.user_settings (user_id) VALUES (NEW.id);
  RETURN NEW;
END;
$fn$;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION handle_new_user();

-- ---------- Permission helper functions ----------

CREATE OR REPLACE FUNCTION is_household_member(hid UUID) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT EXISTS (SELECT 1 FROM household_members
                 WHERE household_id = hid AND user_id = auth.uid());
$fn$;

CREATE OR REPLACE FUNCTION is_household_admin(hid UUID) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT EXISTS (SELECT 1 FROM household_members
                 WHERE household_id = hid AND user_id = auth.uid() AND is_admin);
$fn$;

-- Create a new household; the creator becomes an admin member
CREATE OR REPLACE FUNCTION create_household(p_name TEXT, p_member_name TEXT, p_role TEXT DEFAULT 'אחר')
RETURNS households
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE h households;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  INSERT INTO households (name) VALUES (p_name) RETURNING * INTO h;
  INSERT INTO household_members (household_id, user_id, name, role, is_admin)
  VALUES (h.id, auth.uid(), p_member_name, p_role, true);
  UPDATE user_settings SET active_household_id = h.id WHERE user_id = auth.uid();
  RETURN h;
END;
$fn$;

-- Join an existing household with an invite code
CREATE OR REPLACE FUNCTION join_household(p_invite_code TEXT, p_member_name TEXT, p_role TEXT DEFAULT 'ילד/ה')
RETURNS households
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE h households;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT * INTO h FROM households WHERE invite_code = upper(p_invite_code);
  IF NOT FOUND THEN RAISE EXCEPTION 'invalid invite code'; END IF;
  INSERT INTO household_members (household_id, user_id, name, role)
  VALUES (h.id, auth.uid(), p_member_name, p_role)
  ON CONFLICT (household_id, user_id) DO NOTHING;
  UPDATE user_settings SET active_household_id = h.id WHERE user_id = auth.uid();
  RETURN h;
END;
$fn$;

-- ---------- Row Level Security ----------

ALTER TABLE households          ENABLE ROW LEVEL SECURITY;
ALTER TABLE users               ENABLE ROW LEVEL SECURITY;
ALTER TABLE household_members   ENABLE ROW LEVEL SECURITY;
ALTER TABLE categories          ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventory_items     ENABLE ROW LEVEL SECURITY;
ALTER TABLE shopping_list_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_settings       ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventory_history   ENABLE ROW LEVEL SECURITY;

-- households
CREATE POLICY households_select ON households FOR SELECT TO authenticated USING (is_household_member(id));
CREATE POLICY households_update ON households FOR UPDATE TO authenticated USING (is_household_admin(id));
CREATE POLICY households_delete ON households FOR DELETE TO authenticated USING (is_household_admin(id));

-- users: own profile, plus profiles of people in the same household
CREATE POLICY users_select ON users FOR SELECT TO authenticated USING (
  id = auth.uid() OR EXISTS (
    SELECT 1 FROM household_members m WHERE m.user_id = users.id AND is_household_member(m.household_id)));
CREATE POLICY users_update ON users FOR UPDATE TO authenticated USING (id = auth.uid());

-- household_members
CREATE POLICY members_select ON household_members FOR SELECT TO authenticated USING (is_household_member(household_id));
CREATE POLICY members_insert ON household_members FOR INSERT TO authenticated WITH CHECK (is_household_admin(household_id));
CREATE POLICY members_update ON household_members FOR UPDATE TO authenticated USING (is_household_admin(household_id) OR user_id = auth.uid());
CREATE POLICY members_delete ON household_members FOR DELETE TO authenticated USING (is_household_admin(household_id));

-- categories
CREATE POLICY categories_select ON categories FOR SELECT TO authenticated USING (household_id IS NULL OR is_household_member(household_id));
CREATE POLICY categories_insert ON categories FOR INSERT TO authenticated WITH CHECK (household_id IS NOT NULL AND is_household_member(household_id));
CREATE POLICY categories_update ON categories FOR UPDATE TO authenticated USING (household_id IS NOT NULL AND is_household_member(household_id));
CREATE POLICY categories_delete ON categories FOR DELETE TO authenticated USING (household_id IS NOT NULL AND is_household_member(household_id));

-- inventory_items
CREATE POLICY inventory_all ON inventory_items FOR ALL TO authenticated
  USING (is_household_member(household_id)) WITH CHECK (is_household_member(household_id));

-- shopping_list_items
CREATE POLICY shopping_all ON shopping_list_items FOR ALL TO authenticated
  USING (is_household_member(household_id)) WITH CHECK (is_household_member(household_id));

-- user_settings
CREATE POLICY settings_all ON user_settings FOR ALL TO authenticated
  USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());

-- inventory_history
CREATE POLICY history_select ON inventory_history FOR SELECT TO authenticated USING (
  EXISTS (SELECT 1 FROM inventory_items i WHERE i.id = inventory_item_id AND is_household_member(i.household_id)));
CREATE POLICY history_insert ON inventory_history FOR INSERT TO authenticated WITH CHECK (
  EXISTS (SELECT 1 FROM inventory_items i WHERE i.id = inventory_item_id AND is_household_member(i.household_id)));

-- ---------- Realtime ----------
ALTER PUBLICATION supabase_realtime ADD TABLE inventory_items, shopping_list_items, household_members;
