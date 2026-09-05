-- 学生証アプリ（gakuseisho）セットアップSQL
-- Supabase の SQL Editor に貼り付けて実行してください（再実行しても安全＝毎回全部貼り直してOK）。
-- 既存の他アプリ（安全点検・保険台帳など）と同じSupabaseプロジェクトに相乗りする前提です。
-- テーブル名はすべて gakuseisho_ で始まるので他アプリと衝突しません。
-- 高等学校での利用を想定（学年・組・出席番号・学校住所・電話番号・校章に対応）。

create table if not exists public.gakuseisho_settings (
  id int primary key default 1,
  school_name text not null default '○○高等学校',
  school_address text not null default '',
  school_phone text not null default '',
  school_crest text,
  principal_name text not null default '',
  apply_pass text not null default 'gakusei2026',
  admin_pass text not null default 'sensei2026',
  next_student_no int not null default 1,
  classes_grade1 int not null default 8,
  classes_grade2 int not null default 8,
  classes_grade3 int not null default 8,
  constraint gakuseisho_settings_singleton check (id = 1)
);
insert into public.gakuseisho_settings (id) values (1) on conflict (id) do nothing;
alter table public.gakuseisho_settings add column if not exists school_address text not null default '';
alter table public.gakuseisho_settings add column if not exists school_phone text not null default '';
alter table public.gakuseisho_settings add column if not exists school_crest text;
alter table public.gakuseisho_settings add column if not exists principal_name text not null default '';
alter table public.gakuseisho_settings add column if not exists classes_grade1 int not null default 8;
alter table public.gakuseisho_settings add column if not exists classes_grade2 int not null default 8;
alter table public.gakuseisho_settings add column if not exists classes_grade3 int not null default 8;

create table if not exists public.gakuseisho_students (
  id uuid primary key default gen_random_uuid(),
  device_id text not null unique,
  name text not null,
  grade text,
  class_name text,
  attendance_no text,
  department text,
  birthdate date,
  photo text,
  status text not null default 'pending' check (status in ('pending','approved','rejected','revoked')),
  student_no int,
  recovery_code text unique,
  created_at timestamptz not null default now(),
  approved_at timestamptz
);
alter table public.gakuseisho_students add column if not exists attendance_no text;
alter table public.gakuseisho_students add column if not exists department text;
alter table public.gakuseisho_students add column if not exists birthdate date;
alter table public.gakuseisho_students add column if not exists recovery_code text unique;

alter table public.gakuseisho_settings enable row level security;
alter table public.gakuseisho_students enable row level security;
-- ポリシーはあえて作らない＝テーブルへの直接アクセスは全拒否。
-- 生徒・先生とも下のRPC関数（SECURITY DEFINER）経由でのみアクセスする。

-- 関数の引数を変更しているものは、古いバージョンを先に削除しておく（再実行を安全にするため）
drop function if exists public.gakuseisho_school_name();
drop function if exists public.gakuseisho_school_info();
drop function if exists public.gakuseisho_apply(text,text,text,text,text,text);
drop function if exists public.gakuseisho_apply(text,text,text,text,text,text,text);
drop function if exists public.gakuseisho_admin_update_settings(text,text,text,text);
drop function if exists public.gakuseisho_admin_update_settings(text,text,text,text,text,text,text);
drop function if exists public.gakuseisho_admin_update_settings(text,text,text,text,text,text,text,text);

-- 引き継ぎコードの生成（内部利用のみ。紛らわしい文字0/O/1/I/Lを除く）
create or replace function public.gakuseisho_gen_recovery_code() returns text
language plpgsql set search_path = '' as $$
declare chars text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'; result text := ''; i int;
begin
  for i in 1..8 loop
    result := result || substr(chars, (floor(random()*length(chars))+1)::int, 1);
    if i = 4 then result := result || '-'; end if;
  end loop;
  return result;
end; $$;
revoke all on function public.gakuseisho_gen_recovery_code() from public;

-- 学校情報の表示（申請フォーム・学生証に出す。パスワード不要・誰でも見られる）
create or replace function public.gakuseisho_school_info() returns jsonb
language sql security definer set search_path = '' as $$
  select jsonb_build_object(
    'name', school_name, 'address', school_address, 'phone', school_phone,
    'crest', school_crest, 'principal', principal_name,
    'classes_grade1', classes_grade1, 'classes_grade2', classes_grade2, 'classes_grade3', classes_grade3
  ) from public.gakuseisho_settings where id = 1;
$$;

-- 生徒: 申請（合言葉が合っていれば申請 or 再申請）
create or replace function public.gakuseisho_apply(
  p_device_id text, p_name text, p_grade text, p_class text, p_attendance_no text,
  p_department text, p_birthdate text, p_photo text, p_passcode text
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_pass text; v_row public.gakuseisho_students; v_birthdate date;
begin
  select apply_pass into v_pass from public.gakuseisho_settings where id = 1;
  if v_pass is null or p_passcode is distinct from v_pass then
    raise exception '合言葉が違います';
  end if;
  if p_name is null or length(trim(p_name)) = 0 then
    raise exception '名前を入力してください';
  end if;
  v_birthdate := nullif(trim(p_birthdate), '')::date;

  select * into v_row from public.gakuseisho_students where device_id = p_device_id;
  if found and v_row.status in ('pending','approved') then
    raise exception '既に申請済みです';
  end if;

  insert into public.gakuseisho_students
    (device_id, name, grade, class_name, attendance_no, department, birthdate, photo, status, created_at, recovery_code)
  values
    (p_device_id, p_name, p_grade, p_class, p_attendance_no, p_department, v_birthdate, p_photo, 'pending', now(),
     public.gakuseisho_gen_recovery_code())
  on conflict (device_id) do update set
    name = excluded.name, grade = excluded.grade, class_name = excluded.class_name,
    attendance_no = excluded.attendance_no, department = excluded.department, birthdate = excluded.birthdate,
    photo = excluded.photo, status = 'pending', created_at = now(),
    approved_at = null, student_no = null,
    recovery_code = coalesce(public.gakuseisho_students.recovery_code, excluded.recovery_code)
  returning * into v_row;

  return jsonb_build_object('id', v_row.id, 'status', v_row.status);
end; $$;

-- 生徒: 自分の申請状況を確認（device_idが一致する自分の1件だけ返す）
create or replace function public.gakuseisho_my_status(p_device_id text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_row public.gakuseisho_students;
begin
  select * into v_row from public.gakuseisho_students where device_id = p_device_id;
  if not found then return null; end if;
  return jsonb_build_object(
    'id', v_row.id, 'name', v_row.name, 'grade', v_row.grade, 'class_name', v_row.class_name,
    'attendance_no', v_row.attendance_no, 'department', v_row.department, 'birthdate', v_row.birthdate,
    'photo', v_row.photo, 'status', v_row.status, 'student_no', v_row.student_no,
    'created_at', v_row.created_at, 'approved_at', v_row.approved_at, 'recovery_code', v_row.recovery_code
  );
end; $$;

-- 生徒: 引き継ぎコードで別の端末にこの登録を復元する（device_idを返すだけ。中身は返さない）
create or replace function public.gakuseisho_restore(p_recovery_code text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_row public.gakuseisho_students;
begin
  select * into v_row from public.gakuseisho_students where recovery_code = upper(trim(p_recovery_code));
  if not found then
    raise exception 'コードが見つかりません。入力内容を確認してください。';
  end if;
  return jsonb_build_object('device_id', v_row.device_id);
end; $$;

-- 管理: 一覧（先生の管理者パスワードが必要）
create or replace function public.gakuseisho_admin_list(p_admin_pass text) returns setof public.gakuseisho_students
language plpgsql security definer set search_path = '' as $$
begin
  if p_admin_pass is distinct from (select admin_pass from public.gakuseisho_settings where id = 1) then
    raise exception 'パスワードが違います';
  end if;
  return query select * from public.gakuseisho_students
    order by case status when 'pending' then 0 when 'approved' then 1 else 2 end, created_at desc;
end; $$;

-- 管理: 承認（学生証番号を自動採番）
create or replace function public.gakuseisho_admin_approve(p_admin_pass text, p_id uuid) returns public.gakuseisho_students
language plpgsql security definer set search_path = '' as $$
declare v_no int; v_row public.gakuseisho_students;
begin
  if p_admin_pass is distinct from (select admin_pass from public.gakuseisho_settings where id = 1) then
    raise exception 'パスワードが違います';
  end if;
  select next_student_no into v_no from public.gakuseisho_settings where id = 1;
  update public.gakuseisho_settings set next_student_no = v_no + 1 where id = 1;
  update public.gakuseisho_students set status = 'approved', approved_at = now(), student_no = v_no
    where id = p_id returning * into v_row;
  return v_row;
end; $$;

-- 管理: 却下（生徒側は却下後に再申請できる）
create or replace function public.gakuseisho_admin_reject(p_admin_pass text, p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if p_admin_pass is distinct from (select admin_pass from public.gakuseisho_settings where id = 1) then
    raise exception 'パスワードが違います';
  end if;
  update public.gakuseisho_students set status = 'rejected' where id = p_id;
end; $$;

-- 管理: 無効化（卒業・転校などで学生証を止める。生徒側は無効化後に再申請できる）
create or replace function public.gakuseisho_admin_revoke(p_admin_pass text, p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if p_admin_pass is distinct from (select admin_pass from public.gakuseisho_settings where id = 1) then
    raise exception 'パスワードが違います';
  end if;
  update public.gakuseisho_students set status = 'revoked' where id = p_id;
end; $$;

-- 管理: 進級処理（3/31〜4/1の年度切り替え）。1年→2年、2年→3年、3年は卒業扱いで無効化。
-- 承認済みの生徒だけが対象。発行日表示は承認日から自動計算されるため、対象者のapproved_atを
-- 新年度の4/1に更新して「発行日=4/1」表示を新年度に合わせる。
create or replace function public.gakuseisho_admin_promote(p_admin_pass text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_new_year_start date; v_graduated int; v_promoted2 int; v_promoted3 int;
begin
  if p_admin_pass is distinct from (select admin_pass from public.gakuseisho_settings where id = 1) then
    raise exception 'パスワードが違います';
  end if;
  v_new_year_start := make_date(extract(year from now())::int, 4, 1);

  update public.gakuseisho_students set status = 'revoked'
    where status = 'approved' and grade = '3年';
  get diagnostics v_graduated = row_count;

  update public.gakuseisho_students set grade = '3年', class_name = null, approved_at = v_new_year_start
    where status = 'approved' and grade = '2年';
  get diagnostics v_promoted3 = row_count;

  update public.gakuseisho_students set grade = '2年', class_name = null, approved_at = v_new_year_start
    where status = 'approved' and grade = '1年';
  get diagnostics v_promoted2 = row_count;

  return jsonb_build_object('graduated', v_graduated, 'promoted_to_3', v_promoted3, 'promoted_to_2', v_promoted2);
end; $$;

-- 管理: 生徒の組を修正（クラス替え・進級処理後の再設定用）
create or replace function public.gakuseisho_admin_set_class(p_admin_pass text, p_id uuid, p_class_name text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if p_admin_pass is distinct from (select admin_pass from public.gakuseisho_settings where id = 1) then
    raise exception 'パスワードが違います';
  end if;
  update public.gakuseisho_students set class_name = nullif(trim(p_class_name), '') where id = p_id;
end; $$;

-- 管理: 現在の設定を見る（学校名・住所・電話・校章・合言葉・管理者パスワードの確認用）
create or replace function public.gakuseisho_admin_get_settings(p_admin_pass text) returns public.gakuseisho_settings
language plpgsql security definer set search_path = '' as $$
declare v_row public.gakuseisho_settings;
begin
  select * into v_row from public.gakuseisho_settings where id = 1;
  if v_row.admin_pass is distinct from p_admin_pass then
    raise exception 'パスワードが違います';
  end if;
  return v_row;
end; $$;

-- 管理: 設定変更（学校名・住所・電話・校章・校長名・生徒申請用合言葉・管理者パスワード）
-- 各項目は空欄なら「変更なし」として現在の値を維持する（校章は空文字のとき変更なし）
create or replace function public.gakuseisho_admin_update_settings(
  p_admin_pass text, p_school_name text, p_school_address text, p_school_phone text,
  p_school_crest text, p_principal_name text, p_apply_pass text, p_new_admin_pass text,
  p_classes_grade1 int, p_classes_grade2 int, p_classes_grade3 int
) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if p_admin_pass is distinct from (select admin_pass from public.gakuseisho_settings where id = 1) then
    raise exception 'パスワードが違います';
  end if;
  update public.gakuseisho_settings set
    school_name = coalesce(nullif(trim(p_school_name), ''), school_name),
    school_address = coalesce(trim(p_school_address), school_address),
    school_phone = coalesce(trim(p_school_phone), school_phone),
    school_crest = coalesce(nullif(trim(p_school_crest), ''), school_crest),
    principal_name = coalesce(trim(p_principal_name), principal_name),
    apply_pass = coalesce(nullif(trim(p_apply_pass), ''), apply_pass),
    admin_pass = coalesce(nullif(trim(p_new_admin_pass), ''), admin_pass),
    classes_grade1 = least(greatest(coalesce(p_classes_grade1, classes_grade1), 1), 20),
    classes_grade2 = least(greatest(coalesce(p_classes_grade2, classes_grade2), 1), 20),
    classes_grade3 = least(greatest(coalesce(p_classes_grade3, classes_grade3), 1), 20)
  where id = 1;
end; $$;

revoke all on function public.gakuseisho_school_info() from public;
revoke all on function public.gakuseisho_apply(text,text,text,text,text,text,text,text,text) from public;
revoke all on function public.gakuseisho_my_status(text) from public;
revoke all on function public.gakuseisho_restore(text) from public;
revoke all on function public.gakuseisho_admin_list(text) from public;
revoke all on function public.gakuseisho_admin_approve(text,uuid) from public;
revoke all on function public.gakuseisho_admin_reject(text,uuid) from public;
revoke all on function public.gakuseisho_admin_revoke(text,uuid) from public;
revoke all on function public.gakuseisho_admin_promote(text) from public;
revoke all on function public.gakuseisho_admin_set_class(text,uuid,text) from public;
revoke all on function public.gakuseisho_admin_get_settings(text) from public;
revoke all on function public.gakuseisho_admin_update_settings(text,text,text,text,text,text,text,text,int,int,int) from public;

grant execute on function public.gakuseisho_school_info() to anon, authenticated;
grant execute on function public.gakuseisho_apply(text,text,text,text,text,text,text,text,text) to anon, authenticated;
grant execute on function public.gakuseisho_my_status(text) to anon, authenticated;
grant execute on function public.gakuseisho_restore(text) to anon, authenticated;
grant execute on function public.gakuseisho_admin_list(text) to anon, authenticated;
grant execute on function public.gakuseisho_admin_approve(text,uuid) to anon, authenticated;
grant execute on function public.gakuseisho_admin_reject(text,uuid) to anon, authenticated;
grant execute on function public.gakuseisho_admin_revoke(text,uuid) to anon, authenticated;
grant execute on function public.gakuseisho_admin_promote(text) to anon, authenticated;
grant execute on function public.gakuseisho_admin_set_class(text,uuid,text) to anon, authenticated;
grant execute on function public.gakuseisho_admin_get_settings(text) to anon, authenticated;
grant execute on function public.gakuseisho_admin_update_settings(text,text,text,text,text,text,text,text,int,int,int) to anon, authenticated;
