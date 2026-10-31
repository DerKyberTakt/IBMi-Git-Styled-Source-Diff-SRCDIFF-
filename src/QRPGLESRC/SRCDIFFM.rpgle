**FREE
// =====================================================================
//  SRCDIFFM - SRCDIFF diff engine (NOMAIN module)
//
//  Loads two source members through SQL aliases and computes a
//  git-style unified diff entirely in RPG:
//    1. strip common prefix / suffix
//    2. patience diff (lines unique on both sides -> LIS -> anchors),
//       driven by an explicit work stack (no recursion)
//    3. ranges without anchors: Myers O(ND), capped at SRCDIFF_MAXD;
//       above the cap the range is emitted as delete-all / insert-all
//    4. edit script -> display rows with CONTEXT lines (git hunk rules);
//       each hunk header ends with the nearest preceding "function"
//       line of the old member (BEGSR, DCL-PROC, P-spec, DDS record,
//       CL label/SUBR) - see funcText()
//
//  tools/srcdiff_ref.py in the repository is the same algorithm in
//  Python and is used to verify this module line for line.
//
//  Compile: CRTRPGMOD MODULE(lib/SRCDIFFM) SRCFILE(lib/QRPGLESRC)
//           (SQL inside -> CRTSQLRPGI OBJTYPE(*MODULE) ... RPGPPOPT(*LVL2))
//  Target release 7.3 or later.
// =====================================================================
ctl-opt nomain option(*srcstmt : *nodebugio : *nounref) alloc(*teraspace);

/copy QRPGLESRC,SRCDIFF_H

// -------------------------------------------------- loaded members
dcl-c MAXOPS   334000;                 // 2 * SRCDIFF_MAXLINES
dcl-c MAXROWS  668000;
dcl-c MAXWORK  900000;
dcl-c MAXTAB   698000;
dcl-c MAXTRACE 4100000;                // (MAXD+1)*(MAXD+3) = 4,008,003
dcl-c HASHMOD  2147483647;

dcl-s nA int(10) inz(0);               // lines in the old member
dcl-s nB int(10) inz(0);               // lines in the new member
dcl-s pAText pointer inz(*null);
dcl-s pAKey  pointer inz(*null);
dcl-s pAHash pointer inz(*null);
dcl-s pASeq  pointer inz(*null);
dcl-s pACtx  pointer inz(*null);
dcl-s pBText pointer inz(*null);
dcl-s pBKey  pointer inz(*null);
dcl-s pBHash pointer inz(*null);
dcl-s pBSeq  pointer inz(*null);

// based views over the allocated storage (index 1..n)
dcl-s aText char(100) dim(SRCDIFF_MAXLINES) based(pAText);
dcl-s aKey  char(100) dim(SRCDIFF_MAXLINES) based(pAKey);
dcl-s aHash int(20)   dim(SRCDIFF_MAXLINES) based(pAHash);
dcl-s aSeq  packed(6:2) dim(SRCDIFF_MAXLINES) based(pASeq);
dcl-s aCtx  int(10)   dim(SRCDIFF_MAXLINES) based(pACtx);  // nearest function line <= i
dcl-s bText char(100) dim(SRCDIFF_MAXLINES) based(pBText);
dcl-s bKey  char(100) dim(SRCDIFF_MAXLINES) based(pBKey);
dcl-s bHash int(20)   dim(SRCDIFF_MAXLINES) based(pBHash);
dcl-s bSeq  packed(6:2) dim(SRCDIFF_MAXLINES) based(pBSeq);

// -------------------------------------------------- edit script
dcl-ds op_t qualified template;
  type char(1);                        // ' ' '-' '+'
  i int(10);                           // old index (1-based) or 0
  j int(10);                           // new index (1-based) or 0
end-ds;
dcl-s pOps pointer inz(*null);
dcl-ds ops likeds(op_t) dim(MAXOPS) based(pOps);
dcl-s nOps int(10) inz(0);
dcl-s opsAlloc int(10) inz(0);

// -------------------------------------------------- display rows
dcl-s pRows pointer inz(*null);
dcl-ds rows likeds(op_t) dim(MAXROWS) based(pRows);   // '@': i = hunk#, '=': stats
dcl-s nRows int(10) inz(0);
dcl-s rowsAlloc int(10) inz(0);
dcl-s pHdr pointer inz(*null);
dcl-s hdr char(100) dim(SRCDIFF_MAXLINES) based(pHdr);
dcl-s hdrAlloc int(10) inz(0);
dcl-s nHunks int(10) inz(0);
dcl-s nAdds int(10) inz(0);
dcl-s nDels int(10) inz(0);

// -------------------------------------------------- work stack
dcl-ds work_t qualified template;
  kind char(1);                        // 'R' range to diff, 'E' equal range
  alo int(10);                         // 1-based, half open: alo..ahi-1
  ahi int(10);
  blo int(10);
  bhi int(10);
end-ds;
dcl-s pWork pointer inz(*null);
dcl-ds work likeds(work_t) dim(MAXWORK) based(pWork);
dcl-s nWork int(10);
dcl-s workAlloc int(10) inz(0);

// -------------------------------------------------- unique-line table
dcl-ds tab_t qualified template;
  h int(20);
  ia int(10);                          // a representative old index (0 = none)
  ca int(10);                          // count in old range
  jb int(10);
  cb int(10);
end-ds;
dcl-s pTab pointer inz(*null);
dcl-ds tab likeds(tab_t) dim(MAXTAB) based(pTab);
dcl-s tabSize int(10);

// anchors / LIS
dcl-s pPi pointer inz(*null);
dcl-s pPj pointer inz(*null);
dcl-s pTails pointer inz(*null);
dcl-s pPrev pointer inz(*null);
dcl-s pairI int(10) dim(SRCDIFF_MAXLINES) based(pPi);
dcl-s pairJ int(10) dim(SRCDIFF_MAXLINES) based(pPj);
dcl-s tails int(10) dim(SRCDIFF_MAXLINES) based(pTails);
dcl-s prev  int(10) dim(SRCDIFF_MAXLINES) based(pPrev);
dcl-s nPairs int(10);

// Myers
dcl-s v int(10) dim(4010);             // 2*MAXD + 10, index = k + MAXD + 5
dcl-c VOFF 2005;
dcl-s pTrace pointer inz(*null);
dcl-s trace int(10) dim(MAXTRACE) based(pTrace);

dcl-s lastError varchar(200) inz('');

// =====================================================================
//  srcdiff_load - read one member into memory
// =====================================================================
dcl-proc srcdiff_load export;
  dcl-pi *n int(10);
    side char(3) const;
    lib char(10) const;
    file char(10) const;
    mbr char(10) const;
  end-pi;

  dcl-s stmt varchar(300);
  dcl-s alias char(10);
  dcl-s cnt int(10);
  dcl-s i int(10);
  dcl-s k int(10);
  dcl-s seq packed(6:2);
  dcl-s txt char(100);
  dcl-s isOld ind;

  lastError = '';
  isOld = (side = 'OLD');
  if isOld;
    alias = 'SRCDIFF_O';
  else;
    alias = 'SRCDIFF_N';
  endif;
  freeSide(isOld);

  stmt = 'CREATE OR REPLACE ALIAS QTEMP/' + %trim(alias) + ' FOR '
       + %trim(lib) + '/' + %trim(file) + '(' + %trim(mbr) + ')';
  exec sql execute immediate :stmt;
  if sqlFailed();
    setError();
    return -1;
  endif;

  stmt = 'SELECT COUNT(*) FROM QTEMP/' + %trim(alias);
  exec sql prepare s_cnt from :stmt;
  exec sql declare c_cnt cursor for s_cnt;
  exec sql open c_cnt;
  if sqlFailed();
    setError();
    return -1;
  endif;
  exec sql fetch c_cnt into :cnt;
  exec sql close c_cnt;
  if cnt > SRCDIFF_MAXLINES;
    lastError = 'Member ' + %trim(lib) + '/' + %trim(file) + '(' + %trim(mbr)
              + ') has more than ' + %char(SRCDIFF_MAXLINES) + ' lines';
    return -1;
  endif;

  allocSide(isOld : cnt);

  stmt = 'SELECT SRCSEQ, CAST(SRCDTA AS CHAR(100)) FROM QTEMP/' + %trim(alias)
       + ' A ORDER BY RRN(A)';
  exec sql prepare s_rd from :stmt;
  exec sql declare c_rd cursor for s_rd;
  exec sql open c_rd;
  if sqlFailed();
    setError();
    return -1;
  endif;

  i = 0;
  dow i < cnt;
    exec sql fetch c_rd into :seq, :txt;
    if sqlFailed() or sqlstate = '02000';
      leave;
    endif;
    i += 1;
    if isOld;
      aText(i) = txt;
      aSeq(i) = seq;
    else;
      bText(i) = txt;
      bSeq(i) = seq;
    endif;
  enddo;
  exec sql close c_rd;

  if isOld;
    nA = i;
    // function-context index for hunk headers (one pass)
    for k = 1 to nA;
      if funcText(aText(k)) <> '';
        aCtx(k) = k;
      elseif k > 1;
        aCtx(k) = aCtx(k - 1);
      else;
        aCtx(k) = 0;
      endif;
    endfor;
  else;
    nB = i;
  endif;
  return i;
end-proc;

// true when the last SQL statement failed (warnings and end-of-data are ok)
dcl-proc sqlFailed;
  dcl-pi *n ind;
  end-pi;
  return sqlstate <> '00000' and %subst(sqlstate : 1 : 2) <> '01'
         and sqlstate <> '02000';
end-proc;

dcl-proc allocSide;
  dcl-pi *n;
    isOld ind const;
    cnt int(10) const;
  end-pi;
  dcl-s n int(10);
  n = cnt;
  if n < 1;
    n = 1;
  endif;
  if isOld;
    nA = cnt;
    pAText = %alloc(n * 100);
    pAKey  = %alloc(n * 100);
    pAHash = %alloc(n * 8);
    pASeq  = %alloc(n * %size(aSeq));
    pACtx  = %alloc(n * 4);
  else;
    nB = cnt;
    pBText = %alloc(n * 100);
    pBKey  = %alloc(n * 100);
    pBHash = %alloc(n * 8);
    pBSeq  = %alloc(n * %size(bSeq));
  endif;
end-proc;

// =====================================================================
//  srcdiff_run - compute keys, diff, build rows
// =====================================================================
dcl-proc srcdiff_run export;
  dcl-pi *n int(10);
    context int(10) const;
    ignBlank ind const;
  end-pi;

  dcl-s i int(10);

  for i = 1 to nA;
    aKey(i) = makeKey(aText(i) : ignBlank);
    aHash(i) = hashKey(aKey(i));
  endfor;
  for i = 1 to nB;
    bKey(i) = makeKey(bText(i) : ignBlank);
    bHash(i) = hashKey(bKey(i));
  endfor;

  diffKeys();
  return srcdiff_rebuild(context);
end-proc;

// =====================================================================
//  srcdiff_rebuild - edit script -> display rows
// =====================================================================
dcl-proc srcdiff_rebuild export;
  dcl-pi *n int(10);
    context int(10) const;
  end-pi;

  dcl-s pos int(10);
  dcl-s hStart int(10);
  dcl-s hEnd int(10);
  dcl-s gapStart int(10);
  dcl-s k int(10);
  dcl-s ol int(10);
  dcl-s nl int(10);
  dcl-s os int(10);
  dcl-s ns int(10);
  dcl-s need int(10);

  nAdds = 0;
  nDels = 0;
  for k = 1 to nOps;
    if ops(k).type = '+';
      nAdds += 1;
    elseif ops(k).type = '-';
      nDels += 1;
    endif;
  endfor;

  // (re)allocate rows + headers
  need = nOps + nOps + 8;
  if need > MAXROWS;
    need = MAXROWS;
  endif;
  if rowsAlloc < need;
    if pRows <> *null;
      dealloc pRows;
    endif;
    pRows = %alloc(need * %size(op_t));
    rowsAlloc = need;
  endif;
  need = nAdds + nDels + 2;
  if need > SRCDIFF_MAXLINES;
    need = SRCDIFF_MAXLINES;
  endif;
  if hdrAlloc < need;
    if pHdr <> *null;
      dealloc pHdr;
    endif;
    pHdr = %alloc(need * 100);
    hdrAlloc = need;
  endif;

  nRows = 0;
  nHunks = 0;

  if nAdds = 0 and nDels = 0;
    if context >= SRCDIFF_WHOLE;
      for k = 1 to nOps;
        addRow(ops(k));
      endfor;
    endif;
    addStats();
    return nRows;
  endif;

  if context >= SRCDIFF_WHOLE;
    nHunks = 1;
    for k = 1 to nOps;
      addRow(ops(k));
    endfor;
  else;
    pos = 1;
    dow pos <= nOps;
      // next change
      dow pos <= nOps and ops(pos).type = ' ';
        pos += 1;
      enddo;
      if pos > nOps;
        leave;
      endif;
      hStart = pos - context;
      if hStart < 1;
        hStart = 1;
      endif;
      hEnd = pos;
      dow '1';
        dow hEnd <= nOps and ops(hEnd).type <> ' ';
          hEnd += 1;
        enddo;
        gapStart = hEnd;
        dow hEnd <= nOps and ops(hEnd).type = ' ' and hEnd - gapStart < 2 * context;
          hEnd += 1;
        enddo;
        if hEnd <= nOps and ops(hEnd).type <> ' ';
          iter;                        // another change within reach
        endif;
        hEnd = gapStart + context;
        if hEnd > nOps + 1;
          hEnd = nOps + 1;
        endif;
        leave;
      enddo;

      // header: counts and first line numbers (end is exclusive)
      ol = 0;
      nl = 0;
      os = 0;
      ns = 0;
      for k = hStart to hEnd - 1;
        if ops(k).type <> '+';
          ol += 1;
          if os = 0;
            os = ops(k).i;
          endif;
        endif;
        if ops(k).type <> '-';
          nl += 1;
          if ns = 0;
            ns = ops(k).j;
          endif;
        endif;
      endfor;
      if ol = 0;
        os = lastOldBefore(hStart) + 1;
      endif;
      if nl = 0;
        ns = lastNewBefore(hStart) + 1;
      endif;
      nHunks += 1;
      if nHunks <= hdrAlloc;
        hdr(nHunks) = hunkHeader(os : ol : ns : nl);
        // git: nearest "function" line before the hunk's first old line
        if os - 1 >= 1 and os - 1 <= nA;
          if aCtx(os - 1) > 0;
            hdr(nHunks) = %trimr(hdr(nHunks)) + ' '
                        + funcText(aText(aCtx(os - 1)));
          endif;
        endif;
      endif;
      addHeaderRow(nHunks);
      for k = hStart to hEnd - 1;
        addRow(ops(k));
      endfor;
      pos = hEnd;
    enddo;
  endif;

  addStats();
  return nRows;
end-proc;

// =====================================================================
//  accessors
// =====================================================================
dcl-proc srcdiff_count export;
  dcl-pi *n int(10);
  end-pi;
  return nRows;
end-proc;

dcl-proc srcdiff_getRow export;
  dcl-pi *n likeds(srcdiff_row_t);
    idx int(10) const;
  end-pi;
  dcl-ds r likeds(srcdiff_row_t) inz;

  if idx < 1 or idx > nRows;
    r.type = '=';
    return r;
  endif;
  r.type = rows(idx).type;
  select;
  when r.type = ' ';
    r.oldLine = rows(idx).i;
    r.newLine = rows(idx).j;
    r.oldSeq = aSeq(r.oldLine);
    r.newSeq = bSeq(r.newLine);
    r.text = aText(r.oldLine);
  when r.type = '-';
    r.oldLine = rows(idx).i;
    r.oldSeq = aSeq(r.oldLine);
    r.text = aText(r.oldLine);
  when r.type = '+';
    r.newLine = rows(idx).j;
    r.newSeq = bSeq(r.newLine);
    r.text = bText(r.newLine);
  when r.type = '@';
    if rows(idx).i <= hdrAlloc;
      r.text = hdr(rows(idx).i);
    else;
      r.text = '@@ @@';
    endif;
  other;                               // '='
    if nAdds = 0 and nDels = 0;
      r.text = 'Members are identical';
    elseif nHunks = 1;
      r.text = '1 hunk, +' + %char(nAdds) + ' -' + %char(nDels);
    else;
      r.text = %char(nHunks) + ' hunks, +' + %char(nAdds) + ' -' + %char(nDels);
    endif;
  endsl;
  return r;
end-proc;

dcl-proc srcdiff_stats export;
  dcl-pi *n;
    adds int(10);
    dels int(10);
    hunks int(10);
  end-pi;
  adds = nAdds;
  dels = nDels;
  hunks = nHunks;
end-proc;

// first row of the next change group strictly after idx (0 = none)
dcl-proc srcdiff_nextChange export;
  dcl-pi *n int(10);
    idx int(10) const;
  end-pi;
  dcl-s k int(10);
  k = idx + 1;
  if k < 1;
    k = 1;
  endif;
  // skip the rest of the current group
  dow k <= nRows and isChange(k) and k > 1 and isChange(k - 1);
    k += 1;
  enddo;
  dow k <= nRows;
    if isChange(k) and (k = 1 or not isChange(k - 1));
      return k;
    endif;
    k += 1;
  enddo;
  return 0;
end-proc;

// first row of the previous change group strictly before idx (0 = none)
dcl-proc srcdiff_prevChange export;
  dcl-pi *n int(10);
    idx int(10) const;
  end-pi;
  dcl-s k int(10);
  k = idx - 1;
  if k > nRows;
    k = nRows;
  endif;
  dow k >= 1;
    if isChange(k) and (k = 1 or not isChange(k - 1));
      return k;
    endif;
    k -= 1;
  enddo;
  return 0;
end-proc;

dcl-proc srcdiff_error export;
  dcl-pi *n varchar(200);
  end-pi;
  return lastError;
end-proc;

dcl-proc srcdiff_free export;
  dcl-pi *n;
  end-pi;
  freeSide(*on);
  freeSide(*off);
  if pOps <> *null;
    dealloc pOps;
    opsAlloc = 0;
  endif;
  if pRows <> *null;
    dealloc pRows;
    rowsAlloc = 0;
  endif;
  if pHdr <> *null;
    dealloc pHdr;
    hdrAlloc = 0;
  endif;
  nOps = 0;
  nRows = 0;
end-proc;

// =====================================================================
//  internal: keys and hashing
// =====================================================================
dcl-proc makeKey;
  dcl-pi *n char(100);
    text char(100) const;
    ignBlank ind const;
  end-pi;
  dcl-s outKey char(100);
  dcl-s i int(10);
  dcl-s o int(10);
  dcl-s len int(10);
  dcl-s inBlank ind;

  if not ignBlank;
    return text;                       // trailing blanks never count
  endif;
  // collapse every run of blanks to one blank, drop leading blanks
  outKey = *blanks;
  o = 0;
  inBlank = *on;                       // suppress leading blanks
  len = %len(%trimr(text));
  for i = 1 to len;
    if %subst(text : i : 1) = ' ';
      if not inBlank;
        o += 1;
        %subst(outKey : o : 1) = ' ';
        inBlank = *on;
      endif;
    else;
      o += 1;
      %subst(outKey : o : 1) = %subst(text : i : 1);
      inBlank = *off;
    endif;
  endfor;
  return outKey;
end-proc;

dcl-proc hashKey;
  dcl-pi *n int(20);
    key char(100) const;
  end-pi;
  dcl-ds b;
    ch char(1);
    u uns(3) overlay(ch);
  end-ds;
  dcl-s h int(20) inz(5381);
  dcl-s i int(10);
  dcl-s len int(10);

  len = %len(%trimr(key));
  for i = 1 to len;
    ch = %subst(key : i : 1);
    h = %rem(h * 33 + u : HASHMOD);
  endfor;
  return h;
end-proc;

dcl-proc eqLine;
  dcl-pi *n ind;
    i int(10) const;
    j int(10) const;
  end-pi;
  return aHash(i) = bHash(j) and aKey(i) = bKey(j);
end-proc;

// =====================================================================
//  internal: edit script (patience + Myers), explicit work stack
// =====================================================================
dcl-proc diffKeys;
  dcl-s need int(10);
  dcl-ds w likeds(work_t);
  dcl-s alo int(10);
  dcl-s ahi int(10);
  dcl-s blo int(10);
  dcl-s bhi int(10);
  dcl-s s int(10);
  dcl-s t int(10);
  dcl-s k int(10);
  dcl-s ca int(10);
  dcl-s cb int(10);
  dcl-s hasTail ind;
  dcl-ds tail likeds(work_t);

  // storage
  need = nA + nB + 8;
  if opsAlloc < need;
    if pOps <> *null;
      dealloc pOps;
    endif;
    pOps = %alloc(need * %size(op_t));
    opsAlloc = need;
  endif;
  nOps = 0;

  need = 3 * (nA + nB) + 64;
  if need > MAXWORK;
    need = MAXWORK;
  endif;
  pWork = %alloc(need * %size(work_t));
  workAlloc = need;
  need = 2 * (nA + nB) + 3;
  if need > MAXTAB;
    need = MAXTAB;
  endif;
  pTab = %alloc(need * %size(tab_t));
  need = nA + 1;
  if nB + 1 < need;
    need = nB + 1;
  endif;
  pPi = %alloc(need * 4);
  pPj = %alloc(need * 4);
  pTails = %alloc(need * 4);
  pPrev = %alloc(need * 4);

  nWork = 1;
  work(1).kind = 'R';
  work(1).alo = 1;
  work(1).ahi = nA + 1;
  work(1).blo = 1;
  work(1).bhi = nB + 1;

  dow nWork > 0;
    w = work(nWork);
    nWork -= 1;
    alo = w.alo;
    ahi = w.ahi;
    blo = w.blo;
    bhi = w.bhi;

    if w.kind = 'E';
      for t = 0 to ahi - alo - 1;
        pushOp(' ' : alo + t : blo + t);
      endfor;
      iter;
    endif;

    // common prefix
    dow alo < ahi and blo < bhi and eqLine(alo : blo);
      pushOp(' ' : alo : blo);
      alo += 1;
      blo += 1;
    enddo;
    // common suffix -> one equal range, emitted after the middle
    s = 0;
    dow alo < ahi - s and blo < bhi - s and eqLine(ahi - 1 - s : bhi - 1 - s);
      s += 1;
    enddo;
    hasTail = (s > 0);
    if hasTail;
      tail.kind = 'E';
      tail.alo = ahi - s;
      tail.ahi = ahi;
      tail.blo = bhi - s;
      tail.bhi = bhi;
      ahi -= s;
      bhi -= s;
    endif;

    select;
    when alo = ahi and blo = bhi;
      // nothing in the middle
    when alo = ahi;
      for t = blo to bhi - 1;
        pushOp('+' : 0 : t);
      endfor;
    when blo = bhi;
      for t = alo to ahi - 1;
        pushOp('-' : t : 0);
      endfor;
    other;
      findAnchors(alo : ahi : blo : bhi);
      if nPairs = 0;
        if not myers(alo : ahi : blo : bhi);
          for t = alo to ahi - 1;
            pushOp('-' : t : 0);
          endfor;
          for t = blo to bhi - 1;
            pushOp('+' : 0 : t);
          endfor;
        endif;
      else;
        // push suffix first (pops last), then segments in reverse order
        if hasTail;
          pushWork(tail);
          hasTail = *off;
        endif;
        // segments: gap0, anchor1, gap1, anchor2, ..., gapN  (reverse)
        ca = pairI(nPairs) + 1;
        cb = pairJ(nPairs) + 1;
        pushRange('R' : ca : ahi : cb : bhi);
        for k = nPairs downto 1;
          pushRange('E' : pairI(k) : pairI(k) + 1 : pairJ(k) : pairJ(k) + 1);
          if k > 1;
            pushRange('R' : pairI(k - 1) + 1 : pairI(k) : pairJ(k - 1) + 1 : pairJ(k));
          else;
            pushRange('R' : alo : pairI(k) : blo : pairJ(k));
          endif;
        endfor;
      endif;
    endsl;

    if hasTail;
      pushWork(tail);
    endif;
  enddo;

  dealloc pWork;
  workAlloc = 0;
  dealloc pTab;
  dealloc pPi;
  dealloc pPj;
  dealloc pTails;
  dealloc pPrev;
end-proc;

dcl-proc pushOp;
  dcl-pi *n;
    type char(1) const;
    i int(10) const;
    j int(10) const;
  end-pi;
  if nOps >= opsAlloc;
    return;                            // cannot happen: ops <= n + m
  endif;
  nOps += 1;
  ops(nOps).type = type;
  ops(nOps).i = i;
  ops(nOps).j = j;
end-proc;

dcl-proc pushWork;
  dcl-pi *n;
    w likeds(work_t) const;
  end-pi;
  if nWork >= workAlloc;
    return;                            // only with > ~300k lines in total
  endif;
  nWork += 1;
  work(nWork) = w;
end-proc;

dcl-proc pushRange;
  dcl-pi *n;
    kind char(1) const;
    alo int(10) const;
    ahi int(10) const;
    blo int(10) const;
    bhi int(10) const;
  end-pi;
  if nWork >= workAlloc;
    return;
  endif;
  nWork += 1;
  work(nWork).kind = kind;
  work(nWork).alo = alo;
  work(nWork).ahi = ahi;
  work(nWork).blo = blo;
  work(nWork).bhi = bhi;
end-proc;

// ---------------------------------------------------------------
//  findAnchors - lines unique in a[alo..ahi) and b[blo..bhi),
//  then longest increasing subsequence on the b index.
//  Result: pairI/pairJ(1..nPairs), increasing in both.
// ---------------------------------------------------------------
dcl-proc findAnchors;
  dcl-pi *n;
    alo int(10) const;
    ahi int(10) const;
    blo int(10) const;
    bhi int(10) const;
  end-pi;
  dcl-s i int(10);
  dcl-s j int(10);
  dcl-s slot int(10);
  dcl-s n int(10);
  dcl-s lo int(10);
  dcl-s hi int(10);
  dcl-s mid int(10);
  dcl-s len int(10);
  dcl-s idx int(10);

  nPairs = 0;
  tabSize = 2 * ((ahi - alo) + (bhi - blo)) + 3;
  for slot = 1 to tabSize;
    tab(slot).h = -1;
    tab(slot).ia = 0;
    tab(slot).ca = 0;
    tab(slot).jb = 0;
    tab(slot).cb = 0;
  endfor;

  for i = alo to ahi - 1;
    slot = findSlotA(i);
    if tab(slot).ca = 0;
      tab(slot).h = aHash(i);
      tab(slot).ia = i;
    endif;
    tab(slot).ca += 1;
  endfor;
  for j = blo to bhi - 1;
    slot = findSlotB(j);
    if tab(slot).ca = 0 and tab(slot).cb = 0;
      tab(slot).h = bHash(j);
    endif;
    if tab(slot).cb = 0;
      tab(slot).jb = j;
    endif;
    tab(slot).cb += 1;
  endfor;

  // pairs in old order
  n = 0;
  for i = alo to ahi - 1;
    slot = findSlotA(i);
    if tab(slot).ca = 1 and tab(slot).cb = 1;
      n += 1;
      pairI(n) = i;
      pairJ(n) = tab(slot).jb;
    endif;
  endfor;
  if n = 0;
    return;
  endif;

  // LIS on pairJ (patience sorting with back links)
  len = 0;
  for idx = 1 to n;
    lo = 1;
    hi = len + 1;
    dow lo < hi;
      mid = %div(lo + hi : 2);
      if pairJ(tails(mid)) < pairJ(idx);
        lo = mid + 1;
      else;
        hi = mid;
      endif;
    enddo;
    if lo > 1;
      prev(idx) = tails(lo - 1);
    else;
      prev(idx) = 0;
    endif;
    tails(lo) = idx;
    if lo > len;
      len = lo;
    endif;
  endfor;

  // walk the chain back into tails(1..len), then compact pairI/pairJ
  // forward (tails(mid) >= mid, so no read hits an already written slot)
  idx = tails(len);
  for mid = len downto 1;
    tails(mid) = idx;
    idx = prev(idx);
  endfor;
  for mid = 1 to len;
    pairI(mid) = pairI(tails(mid));
    pairJ(mid) = pairJ(tails(mid));
  endfor;
  nPairs = len;
end-proc;

// slot for old line i: existing entry with the same key, or a free one
dcl-proc findSlotA;
  dcl-pi *n int(10);
    i int(10) const;
  end-pi;
  dcl-s slot int(10);
  slot = %rem(aHash(i) : tabSize) + 1;
  dow '1';
    if tab(slot).ca = 0 and tab(slot).cb = 0;
      return slot;
    endif;
    if tab(slot).h = aHash(i);
      if tab(slot).ca > 0;
        if aKey(tab(slot).ia) = aKey(i);
          return slot;
        endif;
      elseif bKey(tab(slot).jb) = aKey(i);
        return slot;
      endif;
    endif;
    slot += 1;
    if slot > tabSize;
      slot = 1;
    endif;
  enddo;
end-proc;

dcl-proc findSlotB;
  dcl-pi *n int(10);
    j int(10) const;
  end-pi;
  dcl-s slot int(10);
  slot = %rem(bHash(j) : tabSize) + 1;
  dow '1';
    if tab(slot).ca = 0 and tab(slot).cb = 0;
      return slot;
    endif;
    if tab(slot).h = bHash(j);
      if tab(slot).ca > 0;
        if aKey(tab(slot).ia) = bKey(j);
          return slot;
        endif;
      elseif bKey(tab(slot).jb) = bKey(j);
        return slot;
      endif;
    endif;
    slot += 1;
    if slot > tabSize;
      slot = 1;
    endif;
  enddo;
end-proc;

// ---------------------------------------------------------------
//  myers - O(ND) forward diff of a[alo..ahi) vs b[blo..bhi).
//  Returns *off when the edit distance exceeds SRCDIFF_MAXD.
//  trace row d holds v(k) for k = -(d+1)..(d+1); offset d*(d+2).
// ---------------------------------------------------------------
dcl-proc myers;
  dcl-pi *n ind;
    alo int(10) const;
    ahi int(10) const;
    blo int(10) const;
    bhi int(10) const;
  end-pi;
  dcl-s n int(10);
  dcl-s m int(10);
  dcl-s dmax int(10);
  dcl-s d int(10);
  dcl-s k int(10);
  dcl-s x int(10);
  dcl-s y int(10);
  dcl-s px int(10);
  dcl-s py int(10);
  dcl-s pk int(10);
  dcl-s found ind;
  dcl-s base int(10);
  dcl-s dFound int(10);
  dcl-s cnt int(10);
  dcl-s t int(10);
  dcl-s size int(20);

  n = ahi - alo;
  m = bhi - blo;
  dmax = n + m;
  if dmax > SRCDIFF_MAXD;
    dmax = SRCDIFF_MAXD;
  endif;

  size = (dmax + 1) * (dmax + 3);
  pTrace = %alloc(size * 4);

  clear v;                             // v(k+1) = 0 seeds the first step

  found = *off;
  for d = 0 to dmax;
    // snapshot v for k = -(d+1)..(d+1)
    base = d * (d + 2);
    for k = -(d + 1) to d + 1;
      trace(base + k + d + 2) = v(k + VOFF);
    endfor;
    for k = -d to d by 2;
      if k = -d or (k <> d and v(k - 1 + VOFF) < v(k + 1 + VOFF));
        x = v(k + 1 + VOFF);
      else;
        x = v(k - 1 + VOFF) + 1;
      endif;
      y = x - k;
      dow x < n and y < m and eqLine(alo + x : blo + y);
        x += 1;
        y += 1;
      enddo;
      v(k + VOFF) = x;
      if x >= n and y >= m;
        found = *on;
        dFound = d;
        leave;
      endif;
    endfor;
    if found;
      leave;
    endif;
  endfor;

  if not found;
    dealloc pTrace;
    return *off;
  endif;

  // backtrack: ops are produced in reverse into the tail of the ops
  // array, then reversed in place
  cnt = 0;
  x = n;
  y = m;
  for d = dFound downto 0;
    base = d * (d + 2);
    k = x - y;
    if k = -d or (k <> d and trace(base + k - 1 + d + 2) < trace(base + k + 1 + d + 2));
      pk = k + 1;
    else;
      pk = k - 1;
    endif;
    px = trace(base + pk + d + 2);
    py = px - pk;
    dow x > px and y > py;
      x -= 1;
      y -= 1;
      pushOp(' ' : alo + x : blo + y);
      cnt += 1;
    enddo;
    if d > 0;
      if x = px;
        pushOp('+' : 0 : blo + py);
      else;
        pushOp('-' : alo + px : 0);
      endif;
      cnt += 1;
    endif;
    x = px;
    y = py;
  endfor;

  // reverse the last cnt ops
  for t = 0 to %div(cnt : 2) - 1;
    swapOps(nOps - cnt + 1 + t : nOps - t);
  endfor;

  dealloc pTrace;
  return *on;
end-proc;

dcl-proc swapOps;
  dcl-pi *n;
    p int(10) const;
    q int(10) const;
  end-pi;
  dcl-ds tmp likeds(op_t);
  tmp = ops(p);
  ops(p) = ops(q);
  ops(q) = tmp;
end-proc;

// =====================================================================
//  internal: rows
// =====================================================================
dcl-proc addRow;
  dcl-pi *n;
    op likeds(op_t) const;
  end-pi;
  if nRows >= rowsAlloc;
    return;
  endif;
  nRows += 1;
  rows(nRows) = op;
end-proc;

dcl-proc addHeaderRow;
  dcl-pi *n;
    hunk int(10) const;
  end-pi;
  if nRows >= rowsAlloc;
    return;
  endif;
  nRows += 1;
  rows(nRows).type = '@';
  rows(nRows).i = hunk;
  rows(nRows).j = 0;
end-proc;

dcl-proc addStats;
  if nRows >= rowsAlloc;
    return;
  endif;
  nRows += 1;
  rows(nRows).type = '=';
  rows(nRows).i = 0;
  rows(nRows).j = 0;
end-proc;

dcl-proc isChange;
  dcl-pi *n ind;
    k int(10) const;
  end-pi;
  if k < 1 or k > nRows;
    return *off;
  endif;
  return rows(k).type = '-' or rows(k).type = '+';
end-proc;

// last old line number used by an op before position start (0 = none)
dcl-proc lastOldBefore;
  dcl-pi *n int(10);
    hStart int(10) const;
  end-pi;
  dcl-s k int(10);
  for k = hStart - 1 downto 1;
    if ops(k).type <> '+';
      return ops(k).i;
    endif;
  endfor;
  return 0;
end-proc;

dcl-proc lastNewBefore;
  dcl-pi *n int(10);
    hStart int(10) const;
  end-pi;
  dcl-s k int(10);
  for k = hStart - 1 downto 1;
    if ops(k).type <> '-';
      return ops(k).j;
    endif;
  endfor;
  return 0;
end-proc;

// git-style "@@ -os,ol +ns,nl @@" (",1" omitted; empty range at line-1)
dcl-proc hunkHeader;
  dcl-pi *n varchar(100);
    os int(10) const;
    ol int(10) const;
    ns int(10) const;
    nl int(10) const;
  end-pi;
  return '@@ -' + rangeText(os : ol) + ' +' + rangeText(ns : nl) + ' @@';
end-proc;

dcl-proc rangeText;
  dcl-pi *n varchar(24);
    s int(10) const;
    l int(10) const;
  end-pi;
  if l = 0;
    return %char(s - 1) + ',0';
  elseif l = 1;
    return %char(s);
  endif;
  return %char(s) + ',' + %char(l);
end-proc;

// ---------------------------------------------------------------
//  funcText - text to show after a hunk header when this line starts
//  a "function" (git funcname); '' otherwise.  Same rules as
//  func_text() in tools/srcdiff_ref.py:
//    fixed C-spec  col 6 C, col 7 not *, cols 26-35 BEGSR  -> from col 6
//    fixed P-spec  col 6 P, col 7 not *, col 24 B          -> from col 6
//    DDS record    col 6 A, col 7 not *, col 17 R          -> from col 6
//    free RPG      line, or line from col 8, starts DCL-PROC / BEGSR
//    CL            line starts SUBR, or a label NAME: (not a comment)
// ---------------------------------------------------------------
dcl-proc funcText;
  dcl-pi *n varchar(100);
    text char(100) const;
  end-pi;
  dcl-c LO 'abcdefghijklmnopqrstuvwxyz';
  dcl-c UP 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  dcl-c LBL1 'ABCDEFGHIJKLMNOPQRSTUVWXYZ@#$';
  dcl-c LBLN 'ABCDEFGHIJKLMNOPQRSTUVWXYZ@#$0123456789_';
  dcl-s u char(100);
  dcl-s cand varchar(100);
  dcl-s cu varchar(100);
  dcl-s k int(10);
  dcl-s n int(10);

  u = %xlate(LO : UP : text);
  if %subst(u : 7 : 1) <> '*';
    if %subst(u : 6 : 1) = 'C' and %trim(%subst(u : 26 : 10)) = 'BEGSR';
      return %trim(%subst(text : 6));
    endif;
    if %subst(u : 6 : 1) = 'P' and %subst(u : 24 : 1) = 'B';
      return %trim(%subst(text : 6));
    endif;
    if %subst(u : 6 : 1) = 'A' and %subst(u : 17 : 1) = 'R';
      return %trim(%subst(text : 6));
    endif;
  endif;

  cand = %trim(text);
  if isFreeBegin(cand);
    return cand;
  endif;
  cand = %trim(%subst(text : 8));
  if isFreeBegin(cand);
    return cand;
  endif;

  cand = %trim(text);
  cu = %xlate(LO : UP : cand);
  n = %len(cu);
  if n >= 5;
    if %subst(cu : 1 : 5) = 'SUBR ';
      return cand;
    endif;
  endif;
  if n > 0;
    if %scan(%subst(cu : 1 : 1) : LBL1) > 0;
      k = 1;
      dow k < n and k < 10;
        if %scan(%subst(cu : k + 1 : 1) : LBLN) = 0;
          leave;
        endif;
        k += 1;
      enddo;
      if k < n;
        if %subst(cu : k + 1 : 1) = ':';
          return cand;
        endif;
      endif;
    endif;
  endif;
  return '';
end-proc;

dcl-proc isFreeBegin;
  dcl-pi *n ind;
    cand varchar(100) const;
  end-pi;
  dcl-c LO 'abcdefghijklmnopqrstuvwxyz';
  dcl-c UP 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  dcl-s cu varchar(100);

  cu = %xlate(LO : UP : cand);
  if %len(cu) >= 9;
    if %subst(cu : 1 : 9) = 'DCL-PROC ';
      return *on;
    endif;
  endif;
  if %len(cu) >= 6;
    if %subst(cu : 1 : 6) = 'BEGSR ' or %subst(cu : 1 : 6) = 'BEGSR;';
      return *on;
    endif;
  endif;
  return *off;
end-proc;

dcl-proc freeSide;
  dcl-pi *n;
    isOld ind const;
  end-pi;
  if isOld;
    freePtr(pAText);
    freePtr(pAKey);
    freePtr(pAHash);
    freePtr(pASeq);
    freePtr(pACtx);
    nA = 0;
  else;
    freePtr(pBText);
    freePtr(pBKey);
    freePtr(pBHash);
    freePtr(pBSeq);
    nB = 0;
  endif;
end-proc;

dcl-proc freePtr;
  dcl-pi *n;
    p pointer;
  end-pi;
  if p <> *null;
    dealloc p;
    p = *null;
  endif;
end-proc;

dcl-proc setError;
  dcl-s msg varchar(200);
  dcl-s st char(5);
  exec sql get diagnostics condition 1
           :st = RETURNED_SQLSTATE, :msg = MESSAGE_TEXT;
  lastError = 'SQL' + st + ': ' + msg;
end-proc;
