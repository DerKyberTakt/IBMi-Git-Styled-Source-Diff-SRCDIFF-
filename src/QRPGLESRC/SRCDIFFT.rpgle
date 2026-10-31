**FREE
// =====================================================================
//  SRCDIFFT - SRCDIFF test driver
//
//  Runs the diff engine on two members and writes every display row
//  to SRCDIFFTP so the result can be compared with tools/srcdiff_ref.py:
//
//    CALL SRCDIFFT PARM('DEVLIB' 'QRPGLESRC' 'MYPGM' 'PRODLIB' 'QRPGLESRC'
//                       'MYPGM' '0003' 'N' 'RUN1')
//
//  parms: oldLib oldFile oldMbr newLib newFile newMbr context(4) ignBlank(1) runId(10)
//  Elapsed milliseconds are shown with DSPLY.
//
//  Compile: CRTSQLRPGI OBJ(lib/SRCDIFFT) OBJTYPE(*MODULE) RPGPPOPT(*LVL2)
//           CRTPGM PGM(lib/SRCDIFFT) MODULE(SRCDIFFT SRCDIFFM) ACTGRP(*NEW)
// =====================================================================
ctl-opt main(main) option(*srcstmt : *nodebugio) alloc(*teraspace);

/copy QRPGLESRC,SRCDIFF_H

dcl-f SRCDIFFTP disk usage(*output);

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
    pRunId char(10);
  end-pi;

  dcl-s context int(10);
  dcl-s n int(10);
  dcl-s i int(10);
  dcl-s t0 timestamp;
  dcl-s ms int(20);
  dcl-s msg char(52);
  dcl-ds row likeds(srcdiff_row_t);

  context = %int(pContext);

  t0 = %timestamp();
  if srcdiff_load('OLD' : pOldLib : pOldFile : pOldMbr) < 0;
    msg = srcdiff_error();
    dsply msg;
    return;
  endif;
  if srcdiff_load('NEW' : pNewLib : pNewFile : pNewMbr) < 0;
    msg = srcdiff_error();
    dsply msg;
    return;
  endif;
  n = srcdiff_run(context : pIgnBlank = 'Y');
  ms = %diff(%timestamp() : t0 : *MSECONDS) / 1000;

  exec sql delete from SRCDIFFTP where RUNID = :pRunId;

  for i = 1 to n;
    row = srcdiff_getRow(i);
    RUNID = pRunId;
    LINENO = i;
    TYPE = row.type;
    OSEQ = row.oldSeq;
    NSEQ = row.newSeq;
    OLN = row.oldLine;
    NLN = row.newLine;
    TXT = row.text;
    write SRCDIFFTR;
  endfor;

  srcdiff_free();
  msg = %char(n) + ' rows written, ' + %char(ms) + ' ms';
  dsply msg;
end-proc;
