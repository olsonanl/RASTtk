from __future__ import print_function  # <-- this lets python2 use python3's print function

import sys, time, os, subprocess
from distutils import dir_util  # handle dirs
import argparse
import shutil
import numpy as np
from sklearn.externals import joblib

## Signature is
##
##    eval_matrix predictors matrixDir outDir
##
## where matrixDir contains a matrix (col.h, row.h, X) of the role occurrences in the input genomes.
## XXXXX.out files will be written to outDir, where XXXXXX is the ID of a genome.
## Output files will be appended, not created, because it is expected that there will already be
## completeness data in them. There are other versions of this script that can be called standalone.
## This one is usually invoked from L<p3-eval-genomes.pl>.

def eprint(*args, **kwargs):
    print(*args, file=sys.stderr, **kwargs)


def run_predictor(n_col):
    y = X_all[:, n_col]
    X = np.delete(X_all, n_col, axis=1)
    role_ID = col_names[n_col, 1]

    clfDir = args.trainDir + "/Predictors/" + role_ID + "/Classifiers/" + args.clfType
    clfFile = clfDir + "/" + args.clfType
    ldaFile = clfDir + "/LDA_vars"

    if args.LDA:
        vars_to_use = np.genfromtxt(ldaFile, delimiter='\t', dtype=int)
        X_feat = X[:, vars_to_use]
        if vars_to_use.shape[0] == 1:
            X_feat = X_feat.reshape(-1, 1)

    else:
        X_feat = X

    clf = joblib.load(clfFile)
    results = clf.predict(X_feat)
    results = results.tolist()
    results.append(n_col)
    eprint("Completed %d: %s predictor." % (n_col, role_ID))
    return results


stime = time.time()

parser = argparse.ArgumentParser(description='Evaluate a matrix of roles for consistency.')
parser.add_argument("trainDir", help="Directory which contains built predictors",
                    type=str)
parser.add_argument("testDir", help="Directory containing built matrix of GTO roles",
                    type=str)
parser.add_argument("outDir", help="output directory",
                    type=str)
parser.add_argument("-c", "--classifier", dest="clfType", default="RandomForestClassifier", help="Type of sklearn classifier to use")
parser.add_argument("--LDA", action="store_true",
                  help="Use Linear Discriminant Analysis")
args = parser.parse_args()
if __name__ == '__main__':
    eprint("Using predictors from " + args.trainDir + ".")
    eprint("Output will be in " + args.outDir + ".")
    if not os.path.isdir(args.testDir):
        sys.stderr.write("not a valid testDir: %s\n" % (args.testDir))
        sys.exit(-1)

X_all = np.genfromtxt(args.testDir + '/X', delimiter='\t')
col_names = np.genfromtxt(args.testDir + '/col.h', delimiter='\t', dtype=str)
genomes = np.genfromtxt(args.testDir + '/row.h', delimiter='\t', dtype=str)

#...genfromtxt reformats a 1-row dataset as a vector, not an array,
#   so the number of dimensions must be reformatted if not 2D array.
if len(X_all.shape) != 2:
        X_all = X_all.reshape(1,-1)
if len(genomes.shape) != 2:
        genomes = genomes.reshape(1, -1)

#X_all[X_all > 5.] = 6.

if __name__ == '__main__':

    predictions = joblib.Parallel(n_jobs=32)(joblib.delayed(run_predictor)(n_col) for n_col in range(X_all.shape[1]))

    predictions = np.asarray(predictions)
    predictions = np.transpose(predictions)
    col_ind = np.asarray(predictions[-1], dtype=int)
    predictions = np.delete(predictions, -1, axis=0)
    predictions = predictions[:,col_ind]

    real_present = X_all > 0
    pred_present = predictions > 0

    coarse_const = 100.0*np.mean(real_present == pred_present, axis=1)
    fine_const = 100.0*np.mean(X_all == predictions, axis=1)
    score_table = genomes[:,1].reshape(-1, 1)
    score_table = np.hstack((score_table, coarse_const.round(2).reshape(-1,1)))
    score_table = np.hstack((score_table, fine_const.round(2).reshape(-1,1)))

    if not os.path.isdir(args.outDir):
            os.mkdir(args.outDir)

    all_summary = []
    for n_row in range(X_all.shape[0]):
        gtoID = genomes[n_row, 1]
        gto_sum_file = args.outDir + "/" + gtoID + ".out"
        coarseNum = str(np.round(coarse_const[n_row], decimals = 1))
        fineNum = str(np.round(fine_const[n_row], decimals = 1))
        summary = ["Coarse Consistency: " + coarseNum]
        summary.append("Fine Consistency: " + fineNum)
        all_summary.append(gtoID + "\t" + coarseNum + "\t" + fineNum)
        for n_col in range(X_all.shape[1]):
            n_pred = predictions[n_row, n_col]
            n_real = X_all[n_row, n_col]

            if n_pred != n_real:
                summary.append(col_names[n_col, 1] + "\t" + str(int(predictions[n_row, n_col])) + "\t" + str(int(X_all[n_row, n_col])))
        sfh = open(gto_sum_file, 'ab')
        np.savetxt(sfh, summary, fmt="%s", delimiter='\t')
        sfh.close()

    np.savetxt(args.testDir + "/summary.out", all_summary, fmt="%s", delimiter ="\t")
    eprint("Finished %d evaluations with %d roles in %0.2f seconds." % (predictions.shape[0], predictions.shape[1], time.time()-stime))
