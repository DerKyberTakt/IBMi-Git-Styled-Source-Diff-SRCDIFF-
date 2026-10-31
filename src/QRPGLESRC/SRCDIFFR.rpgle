**FREE
// =====================================================================
//  SRCDIFFR - SRCDIFF viewer: git-style unified compare on a 5250
//             screen (engine SRCDIFFM)
//
//  Display files: SRCDIFFD (27x132) is opened first; when the device
//  cannot show 27x132 the open fails and SRCDIFFD8 (24x80) is used
//  instead.  Both have the same field names; SRCDIFFD8 is declared
//  with PREFIX(W8_) and its own indicator data structure.
//
//  Called by the SRCDIFF command (CPP SRCDIFFC):
//    CALL SRCDIFFR PARM(oldLib oldFile oldMbr newLib newFile newMbr
//                       context(4) ignBlank(1) rtnMsg(200))
//  rtnMsg is blank on success, otherwise the text of the error.
//
//  Keys: F3/F12 exit  F6 whole member <-> hunks  F10/F11 next/previous
//        change  F14 toggle ignore blanks  F16 top  F17 bottom
//        F19/F20 shift text left/right (24x80 only)
//        Page up/down  Enter with "Go to seq" positions on a SRCSEQ
//
//  Compile: CRTRPGMOD MODULE(lib/SRCDIFFR) SRCFILE(lib/QRPGLESRC)
//           CRTPGM PGM(lib/SRCDIFFR) MODULE(SRCDIFFR SRCDIFFM) ACTGRP(*NEW)
//           (SRCDIFFD and SRCDIFFD8 must both exist at compile time)
// =====================================================================
ctl-opt main(main) option(*srcstmt : *nodebugio) alloc(*teraspace);

/copy QRPGLESRC,SRCDIFF_H

dcl-f SRCDIFFD workstn indds(ind) sfile(SFL1 : rrn) usropn;
dcl-f SRCDIFFD8 workstn indds(ind8) sfile(SFL8 : rrn) prefix(W8_) usropn;

dcl-c LEAD 3;                          // rows shown above a change after F10/F11
dcl-c TXT8LEN 61;                      // text width on 24x80
dcl-c MAXSHIFT 39;                     // 100 - TXT8LEN

dcl-ds ind qualified len(99);
  exit ind pos(3);
  whole ind pos(6);
  nextChg ind pos(10);
  prevChg ind pos(11);
  cancel ind pos(12);
  ignBlk ind pos(14);
  top ind pos(16);
  bottom ind pos(17);
  shiftL ind pos(19);
  shiftR ind pos(20);
  pageDown ind pos(27);
  pageUp ind pos(28);
  sflEnd ind pos(29);
  sflShow ind pos(30);
  isDel ind pos(31);
  isAdd ind pos(32);
  isHdr ind pos(33);
  isStats ind pos(34);
  isCtx ind pos(35);
end-ds;
dcl-ds ind8 likeds(ind);               // SRCDIFFD8 indicators, copied to/from ind

dcl-s rrn packed(5 : 0);
dcl-s wide ind inz(*on);               // *on = SRCDIFFD 27x132 is open
dcl-s pageSize int(10) inz(19);        // = SFLPAG of the open file
dcl-s shift int(10) inz(0);            // 24x80: first text column shown - 1
dcl-s nRows int(10);
dcl-s topRow int(10);
dcl-s context int(10);
dcl-s hunkContext int(10);
dcl-s ignBlank ind;

// ---------------------------------------------------------------
dcl-proc main;
  dcl-pi *n;
    pOldLib char(10);
    pOldFile char(10);
    pOldMbr char(10);
    pNewLib char(10);
    pNewFile char(10);
    pNewMbr char(10);
    pContext char(4);
    pIgnBlank char(1);
    pRtnMsg char(200);
  end-pi;

  dcl-s anchorType char(1);
  dcl-s anchorLine int(10);
  dcl-s cur int(10);
  dcl-s idx int(10);

  pRtnMsg = '';
  monitor;
    context = %int(pContext);
  on-error;
    context = 3;
  endmon;
  if context < 0;
    context = 3;
  endif;
  hunkContext = context;
  if hunkContext >= SRCDIFF_WHOLE;
    hunkContext = 3;
  endif;
  ignBlank = (pIgnBlank = 'Y');

  if srcdiff_load('OLD' : pOldLib : pOldFile : pOldMbr) < 0;
    pRtnMsg = srcdiff_error();
    return;
  endif;
  if srcdiff_load('NEW' : pNewLib : pNewFile : pNewMbr) < 0;
    pRtnMsg = srcdiff_error();
    srcdiff_free();
    return;
  endif;

  if not openScreen();
    pRtnMsg = 'SRCDIFF cannot open display file SRCDIFFD or SRCDIFFD8 +
               on this device';
    srcdiff_free();
    return;
  endif;

  OLDNAM = %trim(pOldLib) + '/' + %trim(pOldFile) + '(' + %trim(pOldMbr) + ')';
  NEWNAM = %trim(pNewLib) + '/' + %trim(pNewFile) + '(' + %trim(pNewMbr) + ')';

  nRows = srcdiff_run(context : ignBlank);
  topRow = 1;
  MSG = '';
  GOTOSEQ = 0;

  dow '1';
    showPage();
    showScreen();
    MSG = '';

    select;
    when ind.exit or ind.cancel;
      leave;

    when ind.pageDown;
      if topRow + pageSize <= nRows;
        topRow += pageSize;
      else;
        MSG = 'Already at the bottom';
      endif;

    when ind.pageUp;
      if topRow > 1;
        topRow -= pageSize;
        if topRow < 1;
          topRow = 1;
        endif;
      else;
        MSG = 'Already at the top';
      endif;

    when ind.top;
      topRow = 1;

    when ind.bottom;
      topRow = nRows - pageSize + 1;
      if topRow < 1;
        topRow = 1;
      endif;

    when ind.shiftL;
      if shift > 0;
        shift -= 20;
        if shift < 0;
          shift = 0;
        endif;
      else;
        MSG = 'Already at column 1';
      endif;

    when ind.shiftR;
      if shift < MAXSHIFT;
        shift += 20;
        if shift > MAXSHIFT;
          shift = MAXSHIFT;
        endif;
      else;
        MSG = 'Already showing the last column';
      endif;

    when ind.whole;
      pageAnchor(anchorType : anchorLine);
      if context >= SRCDIFF_WHOLE;
        context = hunkContext;
      else;
        context = SRCDIFF_WHOLE;
      endif;
      nRows = srcdiff_rebuild(context);
      topRow = locateAnchor(anchorType : anchorLine);

    when ind.ignBlk;
      pageAnchor(anchorType : anchorLine);
      ignBlank = not ignBlank;
      nRows = srcdiff_run(context : ignBlank);
      topRow = locateAnchor(anchorType : anchorLine);

    when ind.nextChg;
      cur = firstChangeOnPage();
      if cur = 0;
        cur = topRow - 1;
      endif;
      idx = srcdiff_nextChange(cur);
      if idx > 0;
        topRow = idx - LEAD;
        if topRow < 1;
          topRow = 1;
        endif;
      else;
        MSG = 'No more changes';
      endif;

    when ind.prevChg;
      cur = firstChangeOnPage();
      if cur = 0;
        cur = topRow;
      endif;
      idx = srcdiff_prevChange(cur);
      if idx > 0;
        topRow = idx - LEAD;
        if topRow < 1;
          topRow = 1;
        endif;
      else;
        MSG = 'No previous change';
      endif;

    other;                             // Enter
      if GOTOSEQ > 0;
        idx = findSeq(GOTOSEQ);
        if idx > 0;
          topRow = idx;
        else;
          MSG = 'Sequence number ' + %trim(fmtSeq(GOTOSEQ)) + ' not found';
        endif;
        GOTOSEQ = 0;
      endif;
    endsl;
  enddo;

  close *all;
  srcdiff_free();
end-proc;

// ---------------------------------------------------------------
//  openScreen - 27x132 file first, 24x80 file when that fails
// ---------------------------------------------------------------
dcl-proc openScreen;
  dcl-pi *n ind;
  end-pi;

  monitor;
    open SRCDIFFD;
    wide = *on;
    pageSize = 19;
    return *on;
  on-error;
  endmon;

  monitor;
    open SRCDIFFD8;
    wide = *off;
    pageSize = 16;
    return *on;
  on-error;
  endmon;

  return *off;
end-proc;

// ---------------------------------------------------------------
//  writeCtl / showScreen - control record I/O for whichever file is
//  open; the 24x80 file gets copies of the header fields and of the
//  indicators, and its input (indicators, Go to seq) is copied back
// ---------------------------------------------------------------
dcl-proc writeCtl;
  if wide;
    write SFLCTL1;
  else;
    copyHeader8();
    ind8 = ind;
    write SFLCTL8;
  endif;
end-proc;

dcl-proc showScreen;
  if wide;
    write FOOTER;
    exfmt SFLCTL1;
  else;
    copyHeader8();
    W8_MSG = MSG;
    ind8 = ind;
    write FOOTER8;
    exfmt SFLCTL8;
    ind = ind8;
    GOTOSEQ = W8_GOTOSEQ;
  endif;
end-proc;

dcl-proc copyHeader8;
  W8_OLDNAM = OLDNAM;
  W8_NEWNAM = NEWNAM;
  W8_CTXTXT = CTXTXT;
  W8_IGNTXT = IGNTXT;
  W8_STATS = STATS;
  W8_POSTXT = POSTXT;
  W8_GOTOSEQ = GOTOSEQ;
end-proc;

// ---------------------------------------------------------------
//  showPage - clear the subfile and write rows topRow..topRow+pageSize-1
// ---------------------------------------------------------------
dcl-proc showPage;
  dcl-s i int(10);
  dcl-s last int(10);
  dcl-ds r likeds(srcdiff_row_t);

  ind.sflShow = *off;
  writeCtl();
  ind.sflShow = *on;

  last = topRow + pageSize - 1;
  if last > nRows;
    last = nRows;
  endif;

  rrn = 0;
  for i = topRow to last;
    r = srcdiff_getRow(i);
    ind.isDel = (r.type = '-');
    ind.isAdd = (r.type = '+');
    ind.isHdr = (r.type = '@');
    ind.isStats = (r.type = '=');
    ind.isCtx = (r.type = ' ');
    rrn += 1;
    if wide;
      MK = markOf(r.type);
      OSEQ = fmtSeq(r.oldSeq);
      NSEQ = fmtSeq(r.newSeq);
      TXT = r.text;
      write SFL1;
    else;
      W8_MK = markOf(r.type);
      W8_OSEQ = fmtSeq(r.oldSeq);
      W8_NSEQ = fmtSeq(r.newSeq);
      if r.type = '@' or r.type = '=' or shift = 0;
        W8_TXT = r.text;               // headers and stats never shift
      else;
        W8_TXT = %subst(r.text : shift + 1 : TXT8LEN);
      endif;
      ind8 = ind;
      write SFL8;
    endif;
  endfor;

  ind.sflEnd = (last >= nRows);
  POSTXT = 'Rows ' + %char(topRow) + '-' + %char(last) + ' of ' + %char(nRows);
  if not wide and shift > 0;
    POSTXT = %trimr(POSTXT) + '  Col ' + %char(shift + 1);
  endif;
  if context >= SRCDIFF_WHOLE;
    CTXTXT = 'All';
  else;
    CTXTXT = %char(context);
  endif;
  if ignBlank;
    IGNTXT = 'Yes';
  else;
    IGNTXT = 'No';
  endif;
  r = srcdiff_getRow(nRows);           // the stats row is always last
  STATS = r.text;
end-proc;

dcl-proc markOf;
  dcl-pi *n char(1);
    type char(1) const;
  end-pi;
  if type = '-' or type = '+';
    return type;
  endif;
  return ' ';
end-proc;

// ---------------------------------------------------------------
//  fmtSeq - SRCSEQ for display, right-justified in 7 positions:
//  blank for 0, "225" for 225.00, "225.01" otherwise
// ---------------------------------------------------------------
dcl-proc fmtSeq;
  dcl-pi *n char(7);
    seq packed(6 : 2) const;
  end-pi;
  dcl-s c varchar(10);
  dcl-s seqTxt char(7);

  if seq = 0;
    return *blanks;
  endif;
  if seq = %int(seq);
    c = %char(%int(seq));
  else;
    c = %char(seq);
    if seq < 1;
      c = '0' + c;                     // %char gives '.01' for 0.01
    endif;
  endif;
  evalr seqTxt = c;
  return seqTxt;
end-proc;

// ---------------------------------------------------------------
//  firstChangeOnPage - row index of the first '-'/'+' on the page
// ---------------------------------------------------------------
dcl-proc firstChangeOnPage;
  dcl-pi *n int(10);
  end-pi;
  dcl-s i int(10);
  dcl-s last int(10);
  dcl-ds r likeds(srcdiff_row_t);

  last = topRow + pageSize - 1;
  if last > nRows;
    last = nRows;
  endif;
  for i = topRow to last;
    r = srcdiff_getRow(i);
    if r.type = '-' or r.type = '+';
      return i;
    endif;
  endfor;
  return 0;
end-proc;

// ---------------------------------------------------------------
//  pageAnchor - remember a line on the current page so the view can
//  be re-positioned after the rows are rebuilt (F6 / F14)
// ---------------------------------------------------------------
dcl-proc pageAnchor;
  dcl-pi *n;
    aType char(1);
    aLine int(10);
  end-pi;
  dcl-s i int(10);
  dcl-s last int(10);
  dcl-ds r likeds(srcdiff_row_t);

  aType = ' ';
  aLine = 0;
  last = topRow + pageSize - 1;
  if last > nRows;
    last = nRows;
  endif;
  // prefer a changed line, else the first context line
  for i = topRow to last;
    r = srcdiff_getRow(i);
    if r.type = '-';
      aType = '-';
      aLine = r.oldLine;
      return;
    elseif r.type = '+';
      aType = '+';
      aLine = r.newLine;
      return;
    endif;
  endfor;
  for i = topRow to last;
    r = srcdiff_getRow(i);
    if r.type = ' ';
      aType = ' ';
      aLine = r.oldLine;
      return;
    endif;
  endfor;
end-proc;

dcl-proc locateAnchor;
  dcl-pi *n int(10);
    aType char(1) const;
    aLine int(10) const;
  end-pi;
  dcl-s i int(10);
  dcl-s hit int(10);
  dcl-ds r likeds(srcdiff_row_t);

  if aLine = 0;
    return 1;
  endif;
  hit = 0;
  for i = 1 to nRows;
    r = srcdiff_getRow(i);
    if aType = '+';
      if r.type <> '-' and r.newLine >= aLine and r.newLine > 0;
        hit = i;
        leave;
      endif;
    else;
      if r.type <> '+' and r.oldLine >= aLine and r.oldLine > 0;
        hit = i;
        leave;
      endif;
    endif;
  endfor;
  if hit = 0;
    return 1;
  endif;
  hit -= LEAD;
  if hit < 1;
    hit = 1;
  endif;
  return hit;
end-proc;

// ---------------------------------------------------------------
//  findSeq - first row whose old or new SRCSEQ is >= seq
// ---------------------------------------------------------------
dcl-proc findSeq;
  dcl-pi *n int(10);
    seq packed(6 : 2) const;
  end-pi;
  dcl-s i int(10);
  dcl-ds r likeds(srcdiff_row_t);

  for i = 1 to nRows;
    r = srcdiff_getRow(i);
    if (r.oldSeq > 0 and r.oldSeq >= seq) or (r.newSeq > 0 and r.newSeq >= seq);
      return i;
    endif;
  endfor;
  return 0;
end-proc;
