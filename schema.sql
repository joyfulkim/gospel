-- ═══════════════════════════════════════════════════════════════
-- 새생명 축제 2026 — Supabase 데이터베이스 스키마
-- Supabase Dashboard > SQL Editor 에 붙여넣고 실행하세요
-- ═══════════════════════════════════════════════════════════════

-- ────────────────────────────────────────────────────────────────
-- 1. profiles: auth.users 확장 (성도 정보 + 역할)
-- ────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.profiles (
  id          UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  full_name   TEXT NOT NULL DEFAULT '성도',
  cell_group  TEXT DEFAULT '',
  role        TEXT NOT NULL DEFAULT 'member' CHECK (role IN ('admin', 'member')),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ────────────────────────────────────────────────────────────────
-- 2. targets: 전도 대상자
-- ────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.targets (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id      UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  name          TEXT NOT NULL,
  phone         TEXT NOT NULL,
  relationship  TEXT NOT NULL DEFAULT '친구',
  status        TEXT NOT NULL DEFAULT '초청전',
  notes         TEXT DEFAULT '',
  invite_count  INT NOT NULL DEFAULT 0,
  prayer_count  INT NOT NULL DEFAULT 0,
  last_contact  DATE,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ────────────────────────────────────────────────────────────────
-- 3. decisions: 결단 카드 (비로그인 공개 제출)
-- ────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.decisions (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name          TEXT NOT NULL,
  phone         TEXT NOT NULL,
  email         TEXT DEFAULT '',
  want_accept   BOOLEAN NOT NULL DEFAULT FALSE,
  want_pray     BOOLEAN NOT NULL DEFAULT FALSE,
  want_baptism  BOOLEAN NOT NULL DEFAULT FALSE,
  want_cell     BOOLEAN NOT NULL DEFAULT FALSE,
  notes         TEXT DEFAULT '',
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ────────────────────────────────────────────────────────────────
-- 4. RLS 활성화
-- ────────────────────────────────────────────────────────────────
ALTER TABLE public.profiles  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.targets   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.decisions ENABLE ROW LEVEL SECURITY;

-- ────────────────────────────────────────────────────────────────
-- 5. profiles RLS 정책
-- ────────────────────────────────────────────────────────────────
-- 본인 프로필 조회/수정
CREATE POLICY "own profile read"   ON public.profiles FOR SELECT USING (auth.uid() = id);
CREATE POLICY "own profile update" ON public.profiles FOR UPDATE USING (auth.uid() = id);

-- 관리자는 전체 프로필 조회/수정
CREATE POLICY "admin read all profiles" ON public.profiles FOR SELECT
  USING (EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin'));
CREATE POLICY "admin update all profiles" ON public.profiles FOR UPDATE
  USING (EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin'));

-- ────────────────────────────────────────────────────────────────
-- 6. targets RLS 정책
-- ────────────────────────────────────────────────────────────────
-- 성도: 본인 대상자만 CRUD
CREATE POLICY "member owns targets" ON public.targets
  FOR ALL USING (auth.uid() = owner_id);

-- 관리자: 전체 대상자 조회 및 수정
CREATE POLICY "admin read all targets" ON public.targets
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
  );
CREATE POLICY "admin update all targets" ON public.targets
  FOR UPDATE USING (
    EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
  );

-- ────────────────────────────────────────────────────────────────
-- 7. decisions RLS 정책
-- ────────────────────────────────────────────────────────────────
-- 누구나 결단 카드 제출 가능
CREATE POLICY "public insert decision" ON public.decisions
  FOR INSERT WITH CHECK (TRUE);

-- 관리자만 조회 가능
CREATE POLICY "admin read decisions" ON public.decisions
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
  );

-- ────────────────────────────────────────────────────────────────
-- 8. 신규 가입 시 profiles 자동 생성 트리거
-- ────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  INSERT INTO public.profiles (id, full_name, role)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data->>'full_name', '성도'),
    'member'
  );
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- ────────────────────────────────────────────────────────────────
-- 9. 기도 횟수 원자적 증가 RPC
-- ────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.increment_prayer(target_id UUID)
RETURNS VOID LANGUAGE SQL SECURITY DEFINER AS $$
  UPDATE public.targets
  SET prayer_count = prayer_count + 1,
      updated_at   = NOW()
  WHERE id = target_id
    AND (
      owner_id = auth.uid()
      OR EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
    );
$$;

-- ────────────────────────────────────────────────────────────────
-- 10. 초청 횟수 증가 RPC
-- ────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.increment_invite(target_id UUID)
RETURNS VOID LANGUAGE SQL SECURITY DEFINER AS $$
  UPDATE public.targets
  SET invite_count = invite_count + 1,
      last_contact = CURRENT_DATE,
      status = CASE WHEN status = '초청전' THEN '초청함' ELSE status END,
      updated_at   = NOW()
  WHERE id = target_id
    AND (
      owner_id = auth.uid()
      OR EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
    );
$$;

-- ════════════════════════════════════════════════════════════════
-- 설정 완료!
-- 최초 관리자 계정은 아래 쿼리로 수동 설정하세요:
-- UPDATE public.profiles SET role = 'admin' WHERE id = '관리자_UUID';
-- 또는: UPDATE public.profiles SET role = 'admin' WHERE id = (
--   SELECT id FROM auth.users WHERE email = 'admin@example.com'
-- );
-- ════════════════════════════════════════════════════════════════
