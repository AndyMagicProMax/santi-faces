-- ============================================================
-- 《面壁者互动小说》账号系统 · Supabase 建表脚本
-- 用法：Supabase 控制台 → 左侧 SQL Editor → New query → 整段粘贴 → RUN
-- 可重复执行，不会报错
-- ============================================================

-- 1) 用户档案表（用户名、注册时间、角色）
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  username    text unique not null,
  role        text not null default 'player',
  created_at  timestamptz not null default now()
);

-- 2) 存档表（每个账号一行，整包进度存在 data 里）
create table if not exists public.progress (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  data        jsonb not null default '{}'::jsonb,
  updated_at  timestamptz not null default now()
);

-- 3) 判断当前登录者是不是管理员（security definer 避免策略自我递归）
create or replace function public.is_admin()
returns boolean
language sql
security definer
stable
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.role = 'admin'
  );
$$;

-- 4) 注册成功后自动建档案 + 建空存档
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
as $$
begin
  insert into public.profiles (id, username, role)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'username', split_part(new.email, '@', 1)),
    'player'
  )
  on conflict (id) do nothing;

  insert into public.progress (user_id)
  values (new.id)
  on conflict (user_id) do nothing;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_user();

-- 5) 开行级安全（RLS）
alter table public.profiles enable row level security;
alter table public.progress enable row level security;

-- 档案：本人可读；管理员可读全部。玩家不能改档案（防止自己把 role 改成 admin）
drop policy if exists "profiles self or admin read" on public.profiles;
create policy "profiles self or admin read" on public.profiles
  for select using (auth.uid() = id or public.is_admin());

-- 存档：本人可读写；管理员只读（方便以后做申诉/找回）
drop policy if exists "progress self rw" on public.progress;
create policy "progress self rw" on public.progress
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists "progress admin read" on public.progress;
create policy "progress admin read" on public.progress
  for select using (public.is_admin());

-- 6) 把某个账号提升为管理员（等你注册好管理员账号后，把用户名替换掉再执行一次）
-- update public.profiles set role = 'admin' where username = '你的管理员用户名';

-- 6.5) 显式授权：即使项目里关掉了“自动给新表授权”，这两张表也能通过 Data API 访问
grant usage on schema public to anon, authenticated;
grant select on public.profiles to authenticated;
grant select, insert, update on public.progress to authenticated;

-- 7) 自查
-- select count(*) from public.profiles;
-- select username, created_at, role from public.profiles order by created_at;
