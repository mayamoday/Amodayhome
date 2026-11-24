# מבנה בסיס הנתונים: בית המשפחה אמודאי

המערכת שומרת את הנתונים ב־**Supabase** (PostgreSQL).
קובץ ה־SQL המלא נמצא ב־[supabase/schema.sql](supabase/schema.sql), והוא המקור המחייב. המסמך הזה מסביר אותו.

- **התחברות:** דרך Supabase Auth (אימייל + סיסמה). הסיסמאות נשמרות ב־`auth.users` של Supabase ולא בטבלאות שלנו.
- **הרשאות:** Row Level Security מופעל על כל הטבלאות. משתמש רואה ומשנה רק נתונים של בית שהוא חבר בו.
- **זמן אמת:** שינויים ב־`inventory_items`, `shopping_list_items` ו־`household_members` מסונכרנים מיד לכל בני המשפחה.

## סקירה כללית

| טבלה | תפקיד |
|------|-------|
| `households` | בית / משפחה. כל הנתונים שייכים למשק בית אחד |
| `users` | פרופיל משתמש, מקושר ל־`auth.users` |
| `household_members` | בני המשפחה ותפקידם |
| `categories` | קטגוריות מלאי (מערכת + פרטיות לכל בית) |
| `inventory_items` | פריטי המלאי בבית |
| `shopping_list_items` | רשימת הקניות |
| `user_settings` | העדפות משתמש והבית הפעיל |
| `inventory_history` | היסטוריית שינויים במלאי |

### קשרים

```
auth.users 1───1 users 1───1 user_settings
households 1───* household_members *───0..1 users
households 1───* categories
households 1───* inventory_items *───1 categories
households 1───* shopping_list_items *───0..1 inventory_items
inventory_items 1───* inventory_history
```

---

## 1. `households`: משקי בית

| עמודה | סוג | חובה | ברירת מחדל | תיאור |
|-------|-----|------|-------------|--------|
| `id` | UUID | ✔ | `gen_random_uuid()` | מפתח ראשי |
| `name` | VARCHAR(100) | ✔ | | שם הבית, למשל "משפחת אמודאי" |
| `invite_code` | VARCHAR(20) | | 8 תווים אקראיים באותיות גדולות | קוד הזמנה לצירוף בני משפחה (ייחודי) |
| `created_at` | TIMESTAMPTZ | ✔ | `now()` | תאריך יצירה |
| `updated_at` | TIMESTAMPTZ | ✔ | `now()` | מתעדכן אוטומטית בטריגר |

**הרשאות:** צפייה לחברי הבית. עדכון ומחיקה למנהלים בלבד. יצירה רק דרך הפונקציה `create_household`.

---

## 2. `users`: פרופיל משתמש

נוצר אוטומטית בהרשמה (טריגר `on_auth_user_created`).

| עמודה | סוג | חובה | ברירת מחדל | תיאור |
|-------|-----|------|-------------|--------|
| `id` | UUID → `auth.users.id` | ✔ | | מפתח ראשי, זהה למזהה ב־Supabase Auth (`ON DELETE CASCADE`) |
| `email` | VARCHAR(255) | ✔ | | אימייל, **ייחודי** |
| `display_name` | VARCHAR(100) | | | שם תצוגה (מגיע מ־`raw_user_meta_data` בהרשמה) |
| `last_login_at` | TIMESTAMPTZ | | | כניסה אחרונה. מתעדכן מהאפליקציה בכל התחברות |
| `created_at` | TIMESTAMPTZ | ✔ | `now()` | |
| `updated_at` | TIMESTAMPTZ | ✔ | `now()` | מתעדכן אוטומטית בטריגר |

**הרשאות:** משתמש רואה את הפרופיל שלו ואת הפרופילים של מי שגר איתו באותו בית. עדכון רק לפרופיל שלו.

---

## 3. `household_members`: בני משפחה

מחבר בין משתמש למשק בית. בן משפחה יכול להיות גם בלי חשבון (למשל ילד קטן), ולכן `user_id` אינו חובה.

| עמודה | סוג | חובה | ברירת מחדל | תיאור |
|-------|-----|------|-------------|--------|
| `id` | UUID | ✔ | `gen_random_uuid()` | מפתח ראשי |
| `household_id` | UUID → `households.id` | ✔ | | שיוך לבית (`ON DELETE CASCADE`) |
| `user_id` | UUID → `users.id` | | `NULL` | חשבון מקושר (`ON DELETE SET NULL`) |
| `name` | VARCHAR(50) | ✔ | | שם, למשל "יואב" |
| `role` | VARCHAR(20) | ✔ | `'ילד/ה'` | `אבא` / `אמא` / `ילד/ה` / `אחר` |
| `is_admin` | BOOLEAN | ✔ | `false` | הרשאת ניהול. מי שיוצר את הבית מקבל `true` |
| `avatar` | VARCHAR(255) | | | אות ראשונה או קישור לתמונה |
| `created_at` | TIMESTAMPTZ | ✔ | `now()` | |

**אילוצים:** `UNIQUE (household_id, user_id)`: משתמש מופיע פעם אחת בכל בית.

**הרשאות:** צפייה לחברי הבית. הוספה ומחיקה למנהלים. עדכון למנהלים או לבן המשפחה עצמו.

---

## 4. `categories`: קטגוריות מלאי

| עמודה | סוג | חובה | ברירת מחדל | תיאור |
|-------|-----|------|-------------|--------|
| `id` | UUID | ✔ | `gen_random_uuid()` | מפתח ראשי |
| `household_id` | UUID → `households.id` | | `NULL` | `NULL` = קטגוריית מערכת משותפת לכולם |
| `name` | VARCHAR(50) | ✔ | | שם הקטגוריה |
| `icon` | VARCHAR(50) | | | שם אייקון Material Symbols |
| `sort_order` | SMALLINT | ✔ | `0` | סדר הצגה |

**קטגוריות מערכת:**

| שם | אייקון | סדר |
|----|--------|-----|
| מקרר | `kitchen` | 1 |
| מזווה | `shelves` | 2 |
| חומרי ניקוי | `cleaning_services` | 3 |
| קפאון | `ac_unit` | 4 |
| כללי | `category` | 5 |

**אילוצים:** `UNIQUE (household_id, name)`, וגם אינדקס ייחודי חלקי `uq_system_categories` על `name` כאשר `household_id IS NULL`, כדי למנוע כפילויות בקטגוריות מערכת.

**הרשאות:** כולם רואים קטגוריות מערכת. חברי בית יכולים להוסיף, לערוך ולמחוק רק קטגוריות של הבית שלהם.

---

## 5. `inventory_items`: פריטי מלאי

| עמודה | סוג | חובה | ברירת מחדל | תיאור |
|-------|-----|------|-------------|--------|
| `id` | UUID | ✔ | `gen_random_uuid()` | מפתח ראשי |
| `household_id` | UUID → `households.id` | ✔ | | שיוך לבית (`ON DELETE CASCADE`) |
| `category_id` | UUID → `categories.id` | ✔ | | קטגוריה (`ON DELETE RESTRICT`) |
| `name` | VARCHAR(100) | ✔ | | שם המוצר, למשל "חלב 3%" |
| `quantity` | INTEGER | ✔ | `1` | כמות במלאי, `CHECK (quantity >= 0)` |
| `status` | VARCHAR(20) | ✔ | `'מלא'` | `מלא` / `חצי` / `כמעט ריק` |
| `notes` | TEXT | | | הערות (שדה "הערות" במסך העריכה) |
| `created_by` | UUID → `household_members.id` | | | מי הוסיף (`ON DELETE SET NULL`) |
| `updated_by` | UUID → `household_members.id` | | | מי עדכן לאחרונה (`ON DELETE SET NULL`) |
| `created_at` | TIMESTAMPTZ | ✔ | `now()` | |
| `last_updated` | TIMESTAMPTZ | ✔ | `now()` | מתעדכן אוטומטית בטריגר |

**אילוצים ואינדקסים:**
- `CHECK (status IN ('מלא', 'חצי', 'כמעט ריק'))`
- `UNIQUE (household_id, name)`: אין שני פריטים עם אותו שם באותו בית
- `idx_inventory_status` על `(household_id, status)`
- `idx_inventory_category` על `(household_id, category_id)`

**חישוב סטטוס לפי כמות** (באפליקציה): 3 ומעלה = `מלא`, 1–2 = `חצי`, 0 = `כמעט ריק`.

**הרשאות:** חברי הבית יכולים לבצע כל פעולה.

---

## 6. `shopping_list_items`: רשימת קניות

| עמודה | סוג | חובה | ברירת מחדל | תיאור |
|-------|-----|------|-------------|--------|
| `id` | UUID | ✔ | `gen_random_uuid()` | מפתח ראשי |
| `household_id` | UUID → `households.id` | ✔ | | שיוך לבית (`ON DELETE CASCADE`) |
| `inventory_item_id` | UUID → `inventory_items.id` | | `NULL` | פריט מלאי מקושר (`ON DELETE SET NULL`) |
| `name` | VARCHAR(100) | ✔ | | שם המוצר לקנייה |
| `requested_quantity` | INTEGER | ✔ | `1` | כמות מבוקשת, `CHECK (requested_quantity > 0)` |
| `note` | VARCHAR(255) | | | הערה, למשל "רק צרור" |
| `added_by` | UUID → `household_members.id` | | | מי הוסיף (`ON DELETE SET NULL`) |
| `added_at` | TIMESTAMPTZ | ✔ | `now()` | |
| `is_completed` | BOOLEAN | ✔ | `false` | סומן כנרכש |
| `completed_by` | UUID → `household_members.id` | | | מי סימן כנרכש |
| `completed_at` | TIMESTAMPTZ | | | מתי נרכש |

**אינדקסים:**
- `idx_shopping_list` על `(household_id, is_completed, added_at DESC)`: הצגת הרשימה
- `idx_shopping_inv` על `(inventory_item_id)`: בדיקה אם פריט מלאי כבר בעגלה

**הרשאות:** חברי הבית יכולים לבצע כל פעולה.

---

## 7. `user_settings`: הגדרות משתמש

נוצר אוטומטית בהרשמה, יחד עם `users`.

| עמודה | סוג | חובה | ברירת מחדל | תיאור |
|-------|-----|------|-------------|--------|
| `user_id` | UUID → `users.id` | ✔ | | מפתח ראשי (`ON DELETE CASCADE`) |
| `notifications_enabled` | BOOLEAN | ✔ | `true` | התראות |
| `dark_mode` | BOOLEAN | ✔ | `false` | מצב כהה |
| `active_household_id` | UUID → `households.id` | | | הבית הפעיל. נקבע ביצירה או בהצטרפות לבית (`ON DELETE SET NULL`) |
| `updated_at` | TIMESTAMPTZ | ✔ | `now()` | מתעדכן אוטומטית בטריגר |

**הרשאות:** כל משתמש רואה ומשנה רק את ההגדרות שלו.

---

## 8. `inventory_history`: היסטוריית מלאי

מתעד כל שינוי בכמות או בסטטוס של פריט.

| עמודה | סוג | חובה | ברירת מחדל | תיאור |
|-------|-----|------|-------------|--------|
| `id` | BIGSERIAL | ✔ | | מפתח ראשי |
| `inventory_item_id` | UUID → `inventory_items.id` | ✔ | | (`ON DELETE CASCADE`) |
| `member_id` | UUID → `household_members.id` | | | מי ביצע את השינוי |
| `action` | VARCHAR(20) | ✔ | | `created` / `updated` / `status_changed` / `restocked` / `deleted` |
| `quantity_before` | INTEGER | | | |
| `quantity_after` | INTEGER | | | |
| `status_before` | VARCHAR(20) | | | |
| `status_after` | VARCHAR(20) | | | |
| `source_shopping_item_id` | UUID → `shopping_list_items.id` | | | אם השינוי נבע מסימון פריט כנרכש |
| `created_at` | TIMESTAMPTZ | ✔ | `now()` | |

**אינדקס:** `idx_history_item` על `(inventory_item_id, created_at DESC)`.

**הרשאות:** חברי הבית יכולים לצפות ולהוסיף. אין עדכון או מחיקה, כך שההיסטוריה לא ניתנת לשינוי.

> **שימו לב:** מחיקת פריט מוחקת גם את כל ההיסטוריה שלו, כי העמודה `inventory_item_id` מוגדרת עם `ON DELETE CASCADE`. מאותה סיבה האפליקציה לא רושמת פעולת `deleted`. אם רוצים לשמור היסטוריה גם אחרי מחיקה, צריך לשנות את העמודה ל־`ON DELETE SET NULL` ולבטל את חובת הערך בה.

---

## פונקציות וטריגרים

### טריגרים

| טריגר | טבלה | מה הוא עושה |
|-------|------|-------------|
| `trg_households_updated` | `households` | מעדכן `updated_at` |
| `trg_users_updated` | `users` | מעדכן `updated_at` |
| `trg_user_settings_updated` | `user_settings` | מעדכן `updated_at` |
| `trg_inventory_updated` | `inventory_items` | מעדכן `last_updated` |
| `on_auth_user_created` | `auth.users` | יוצר שורה ב־`users` וב־`user_settings` למשתמש חדש |

### פונקציות (נקראות מהאפליקציה עם `sb.rpc`)

| פונקציה | פרמטרים | מה היא עושה |
|---------|---------|-------------|
| `create_household` | `p_name`, `p_member_name`, `p_role` (ברירת מחדל `'אחר'`) | יוצרת בית חדש, מוסיפה את המשתמש כמנהל וקובעת אותו כבית הפעיל |
| `join_household` | `p_invite_code`, `p_member_name`, `p_role` (ברירת מחדל `'ילד/ה'`) | מצרפת את המשתמש לבית לפי קוד הזמנה (לא תלוי באותיות גדולות/קטנות) וקובעת אותו כבית הפעיל |

### פונקציות עזר להרשאות

| פונקציה | מחזירה `true` אם… |
|---------|---------------------|
| `is_household_member(hid)` | המשתמש המחובר חבר בבית |
| `is_household_admin(hid)` | המשתמש המחובר מנהל בבית |

---

## התקנה

1. פותחים את הפרויקט ב־Supabase, ואז **SQL Editor**.
2. מריצים את כל התוכן של [supabase/schema.sql](supabase/schema.sql).
3. מוודאים ש־**Authentication → Providers → Email** מופעל.
