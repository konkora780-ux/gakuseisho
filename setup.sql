-- 学生証アプリ（gakuseisho）セットアップSQL
-- Supabase の SQL Editor に貼り付けて一度だけ実行してください。
-- 既存の他アプリ（安全点検・保険台帳など）と同じSupabaseプロジェクトに相乗りする前提です。
-- テーブル名はすべて gakuseisho_ で始まるので他アプリと衝突しません。

create table if not exists public.gakuseisho_settings (
  id int primary key default 1,
  school_name text not null default '○○学校',
  apply_pass text not null default 'gakusei2026',
  admin_pass text not null default 'sensei2026',
  next_student_no int not null default 1,
  constraint gakuseisho_settings_singleton check (id = 1)
);
insert into public.gakuseisho_settings (id) values (1) on conflict (id) do nothing;

create table if not exists public.gakuseisho_students (
  id uuid primary key default gen_random_uuid(),
  device_id text not null unique,
  name text not null,
  grade text,
  class_name text,
  photo text,
  status text not null default 'pending' check (status in ('pending','approved','rejected','revoked')),
  student_no int,
  created_at timestamptz not null default now(),
  approved_at timestamptz
);

alter table public.gakuseisho_settings enable row level security;
alter table public.gakuseisho_students enable row level security;
-- ポリシーはあえて作らない＝テーブルへの直接アクセスは全拒否。
-- 生徒・先生とも下のRPC関数（SECURITY DEFINER）経由でのみアクセスする。

-- 学校名の表示（申請フォームに出す。パスワード不要・誰でも見られる）
create or replace function public.gakuseisho_school_name() returns text
language sql security definer set search_path = '' as $$
  select school_name from public.gakuseisho_settings where id = 1;
$$;

-- 生徒: 申請（合言葉が合っていれば申請 or 再申請）
create or replace function public.gakuseisho_apply(
  p_device_id text, p_name text, p_grade text, p_class text, p_photo text, p_passcode text
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_pass text; v_row public.gakuseisho_students;
begin
  select apply_pass into v_pass from public.gakuseisho_settings where id = 1;
  if v_pass is null or p_passcode is distinct from v_pass then
    raise exception '合言葉が違います';
  end if;
  if p_name is null or length(trim(p_name)) = 0 then
    raise exception '名前を入力してください';
  end if;

  select * into v_row from public.gakuseisho_students where device_id = p_device_id;
  if found and v_row.status in ('pending','approved') then
    raise exception '既に申請済みです';
  end if;

  insert into public.gakuseisho_students (device_id, name, grade, class_name, photo, status, created_at)
  values (p_device_id, p_name, p_grade, p_class, p_photo, 'pending', now())
  on conflict (device_id) do update set
    name = excluded.name, grade = excluded.grade, class_name = excluded.class_name,
    photo = excluded.photo, status = 'pending', created_at = now(),
    approved_at = null, student_no = null
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
    'photo', v_row.photo, 'status', v_row.status, 'student_no', v_row.student_no,
    'created_at', v_row.created_at
  );
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

-- 管理: 無効化（卒業・転校などで学生証を止める）
create or replace function public.gakuseisho_admin_revoke(p_admin_pass text, p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if p_admin_pass is distinct from (select admin_pass from public.gakuseisho_settings where id = 1) then
    raise exception 'パスワードが違います';
  end if;
  update public.gakuseisho_students set status = 'revoked' where id = p_id;
end; $$;

-- 管理: 現在の設定を見る（学校名・合言葉・管理者パスワードの確認用）
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

-- 管理: 設定変更（学校名・生徒申請用合言葉・管理者パスワード）
create or replace function public.gakuseisho_admin_update_settings(
  p_admin_pass text, p_school_name text, p_apply_pass text, p_new_admin_pass text
) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if p_admin_pass is distinct from (select admin_pass from public.gakuseisho_settings where id = 1) then
    raise exception 'パスワードが違います';
  end if;
  update public.gakuseisho_settings set
    school_name = coalesce(nullif(trim(p_school_name), ''), school_name),
    apply_pass = coalesce(nullif(trim(p_apply_pass), ''), apply_pass),
    admin_pass = coalesce(nullif(trim(p_new_admin_pass), ''), admin_pass)
  where id = 1;
end; $$;

revoke all on function public.gakuseisho_school_name() from public;
revoke all on function public.gakuseisho_apply(text,text,text,text,text,text) from public;
revoke all on function public.gakuseisho_my_status(text) from public;
revoke all on function public.gakuseisho_admin_list(text) from public;
revoke all on function public.gakuseisho_admin_approve(text,uuid) from public;
revoke all on function public.gakuseisho_admin_reject(text,uuid) from public;
revoke all on function public.gakuseisho_admin_revoke(text,uuid) from public;
revoke all on function public.gakuseisho_admin_get_settings(text) from public;
revoke all on function public.gakuseisho_admin_update_settings(text,text,text,text) from public;

grant execute on function public.gakuseisho_school_name() to anon, authenticated;
grant execute on function public.gakuseisho_apply(text,text,text,text,text,text) to anon, authenticated;
grant execute on function public.gakuseisho_my_status(text) to anon, authenticated;
grant execute on function public.gakuseisho_admin_list(text) to anon, authenticated;
grant execute on function public.gakuseisho_admin_approve(text,uuid) to anon, authenticated;
grant execute on function public.gakuseisho_admin_reject(text,uuid) to anon, authenticated;
grant execute on function public.gakuseisho_admin_revoke(text,uuid) to anon, authenticated;
grant execute on function public.gakuseisho_admin_get_settings(text) to anon, authenticated;
grant execute on function public.gakuseisho_admin_update_settings(text,text,text,text) to anon, authenticated;
