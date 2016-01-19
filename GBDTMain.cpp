/*
 * GBDTMain.cpp
 *
 *  Created on: 6 Jan 2016
 *      Author: Zeyi Wen
 *		@brief: project main function
 */

#include "DataReader/LibSVMDataReader.h"
#include "Trainer.h"

int main()
{
	/********* read training instances from a file **************/
	vector<vector<float_point> > v_vInstance;
	vector<float_point> v_fLabel;
	string strFileName;
	int nNumofFeatures;
	int nNumofExamples;

	LibSVMDataReader dataReader;
	dataReader.ReadLibSVMDataFormat(v_vInstance, v_fLabel, strFileName, nNumofFeatures, nNumofExamples);

	/********* run the GBDT learning process ******************/
	vector<RegTree> v_Tree;
	Trainer trainer;
	int nNumofTree = 1;
	int nMaxDepth = 2;
	trainer.InitTrainer(nNumofTree, nMaxDepth);
	trainer.TrainGBDT(v_vInstance, v_fLabel, v_Tree);

	//read testing instances from a file


	//run the GBDT prediction process


	return 0;
}


