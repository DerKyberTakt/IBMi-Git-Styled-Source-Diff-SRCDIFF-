/*******************************************************************/
/* SRCDIFF - Compare two source members, git style, on a 5250      */
/*                                                                 */
/* Same parameter shape as CMPPFM so a PDM user-defined option     */
/* only needs the command name changed:                            */
/*   SRCDIFF NEWFILE(&L/&F) NEWMBR(&N) OLDFILE(PRODLIB / *NEWFILE)  */
/*                                                                 */
/* CPP: SRCDIFFC                                                   */
/*******************************************************************/
             CMD        PROMPT('Compare Source Members (diff)')

             PARM       KWD(NEWFILE) TYPE(QNEW) MIN(1) +
                          PROMPT('New file')

             PARM       KWD(NEWMBR) TYPE(*NAME) LEN(10) MIN(1) +
                          PROMPT('New member')

             PARM       KWD(OLDFILE) TYPE(QOLD) +
                          PROMPT('Old file')

             PARM       KWD(OLDMBR) TYPE(*NAME) LEN(10) DFT(*NEWMBR) +
                          SPCVAL((*NEWMBR)) PROMPT('Old member')

             PARM       KWD(CONTEXT) TYPE(*DEC) LEN(4 0) DFT(3) +
                          RANGE(0 9999) +
                          PROMPT('Context lines (9999=all)')

             PARM       KWD(IGNBLANK) TYPE(*CHAR) LEN(4) RSTD(*YES) +
                          DFT(*NO) VALUES(*NO *YES) +
                          PROMPT('Ignore blanks')

 QNEW:       QUAL       TYPE(*NAME) LEN(10) MIN(1)
             QUAL       TYPE(*NAME) LEN(10) DFT(*LIBL) +
                          SPCVAL((*LIBL) (*CURLIB)) PROMPT('Library')

 QOLD:       QUAL       TYPE(*NAME) LEN(10) DFT(*NEWFILE) +
                          SPCVAL((*NEWFILE))
             QUAL       TYPE(*NAME) LEN(10) DFT(*LIBL) +
                          SPCVAL((*LIBL) (*CURLIB)) PROMPT('Library')
