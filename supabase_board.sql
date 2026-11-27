-- ============================================================
-- 《面壁者互动小说》讨论交流区 · Supabase 建表脚本（第 2 段）
-- 用法：Supabase 控制台 → 左侧 SQL Editor → 粘贴整段 → RUN
-- 可重复执行；和已有的 profiles / progress / is_admin() 配套使用
-- ============================================================

-- 1) 留言（一条发言）
create table if not exists public.posts (
  id            bigserial primary key,
  user_id       uuid not null references auth.users(id) on delete cascade,
  username      text not null,
  content       text not null,
  like_count    int  not null default 0,
  comment_count int  not null default 0,
  created_at    timestamptz not null default now()
);

-- 2) 点赞（同一个人对同一条只能点一次）
create table if not exists public.post_likes (
  post_id    bigint not null references public.posts(id) on delete cascade,
  user_id    uuid   not null references auth.users(id) on delete cascade,
  username   text   not null default '',
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);

-- 3) 评论
create table if not exists public.post_comments (
  id         bigserial primary key,
  post_id    bigint not null references public.posts(id) on delete cascade,
  user_id    uuid   not null references auth.users(id) on delete cascade,
  username   text   not null,
  content    text   not null,
  created_at timestamptz not null default now()
);

-- 4) 消息（别人点赞 / 评论了你的留言时，给留言者本人记一条）
create table if not exists public.notifications (
  id         bigserial primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,   -- 收件人（留言作者）
  kind       text not null,                                              -- like | comment
  post_id    bigint not null references public.posts(id) on delete cascade,
  actor      text not null default '',                                   -- 谁点的赞 / 谁评论的
  excerpt    text not null default '',                                   -- 摘要：留言或评论内容前 60 字
  seen       boolean not null default false,
  created_at timestamptz not null default now()
);

create index if not exists posts_created_idx on public.posts (created_at desc);
create index if not exists notifications_user_idx on public.notifications (user_id, seen, created_at desc);
create index if not exists comments_post_idx on public.post_comments (post_id, created_at);

-- 5) 触发器：点赞 / 取消点赞 → 维护计数，并给作者发消息
create or replace function public.on_like_insert()
returns trigger language plpgsql security definer as $$
begin
  update public.posts set like_count = like_count + 1 where id = new.post_id;
  insert into public.notifications (user_id, kind, post_id, actor, excerpt)
  select p.user_id, 'like', p.id, new.username, left(p.content, 60)
  from public.posts p
  where p.id = new.post_id and p.user_id <> new.user_id;
  return new;
end;
$$;

create or replace function public.on_like_delete()
returns trigger language plpgsql security definer as $$
begin
  update public.posts set like_count = greatest(like_count - 1, 0) where id = old.post_id;
  return old;
end;
$$;

drop trigger if exists trg_like_insert on public.post_likes;
create trigger trg_like_insert after insert on public.post_likes
for each row execute function public.on_like_insert();

drop trigger if exists trg_like_delete on public.post_likes;
create trigger trg_like_delete after delete on public.post_likes
for each row execute function public.on_like_delete();

-- 6) 触发器：评论新增 / 删除 → 维护计数，并给作者发消息
create or replace function public.on_comment_insert()
returns trigger language plpgsql security definer as $$
begin
  update public.posts set comment_count = comment_count + 1 where id = new.post_id;
  insert into public.notifications (user_id, kind, post_id, actor, excerpt)
  select p.user_id, 'comment', p.id, new.username, left(new.content, 60)
  from public.posts p
  where p.id = new.post_id and p.user_id <> new.user_id;
  return new;
end;
$$;

create or replace function public.on_comment_delete()
returns trigger language plpgsql security definer as $$
begin
  update public.posts set comment_count = greatest(comment_count - 1, 0) where id = old.post_id;
  return old;
end;
$$;

drop trigger if exists trg_comment_insert on public.post_comments;
create trigger trg_comment_insert after insert on public.post_comments
for each row execute function public.on_comment_insert();

drop trigger if exists trg_comment_delete on public.post_comments;
create trigger trg_comment_delete after delete on public.post_comments
for each row execute function public.on_comment_delete();

-- 7) 开行级安全
alter table public.posts          enable row level security;
alter table public.post_likes     enable row level security;
alter table public.post_comments  enable row level security;
alter table public.notifications  enable row level security;

-- 留言：所有人可看；登录玩家可发（只能以自己的身份发）；只有管理员能删
drop policy if exists "posts read all" on public.posts;
create policy "posts read all" on public.posts
  for select using (true);

drop policy if exists "posts insert self" on public.posts;
create policy "posts insert self" on public.posts
  for insert with check (auth.uid() = user_id);

drop policy if exists "posts delete admin" on public.posts;
create policy "posts delete admin" on public.posts
  for delete using (public.is_admin());

-- 点赞：所有人可看；登录玩家可点（自己的那一行）；本人或管理员可取消
drop policy if exists "likes read all" on public.post_likes;
create policy "likes read all" on public.post_likes
  for select using (true);

drop policy if exists "likes insert self" on public.post_likes;
create policy "likes insert self" on public.post_likes
  for insert with check (auth.uid() = user_id);

drop policy if exists "likes delete self or admin" on public.post_likes;
create policy "likes delete self or admin" on public.post_likes
  for delete using (auth.uid() = user_id or public.is_admin());

-- 评论：所有人可看；登录玩家可评；只有管理员能删
drop policy if exists "comments read all" on public.post_comments;
create policy "comments read all" on public.post_comments
  for select using (true);

drop policy if exists "comments insert self" on public.post_comments;
create policy "comments insert self" on public.post_comments
  for insert with check (auth.uid() = user_id);

drop policy if exists "comments delete admin" on public.post_comments;
create policy "comments delete admin" on public.post_comments
  for delete using (public.is_admin());

-- 消息：只有本人能看 / 标记已读 / 删除
drop policy if exists "notifications self read" on public.notifications;
create policy "notifications self read" on public.notifications
  for select using (auth.uid() = user_id);

drop policy if exists "notifications self update" on public.notifications;
create policy "notifications self update" on public.notifications
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists "notifications self delete" on public.notifications;
create policy "notifications self delete" on public.notifications
  for delete using (auth.uid() = user_id);

-- 8) 显式授权（配合 publishable / anon key 走 Data API）
grant usage on schema public to anon, authenticated;
grant select on public.posts, public.post_likes, public.post_comments to anon, authenticated;
grant insert, delete on public.posts to authenticated;
grant insert, delete on public.post_likes to authenticated;
grant insert, delete on public.post_comments to authenticated;
grant select, insert, update, delete on public.notifications to authenticated;
grant usage, select on all sequences in schema public to authenticated;

-- 9) 自查
-- select count(*) from public.posts;
-- select id, username, left(content,20), like_count, comment_count, created_at from public.posts order by created_at desc limit 10;
