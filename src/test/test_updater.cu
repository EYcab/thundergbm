//
// Created by jiashuai on 18-1-18.
//
#include <thundergbm/tree.h>
#include <thundergbm/dataset.h>
#include <thundergbm/updater/exact_updater.h>
#include <thundergbm/updater/hist_updater.h>
#include <thundergbm/syncmem.h>
#include "gtest/gtest.h"
#include "cuda_profiler_api.h"
//#include "mpi.h"

extern GBMParam global_test_param;

class UpdaterTest : public ::testing::Test {
public:

    GBMParam param = global_test_param;

    void SetUp() override {
        if (!param.verbose) {
            el::Loggers::reconfigureAllLoggers(el::Level::Debug, el::ConfigurationType::Enabled, "false");
            el::Loggers::reconfigureAllLoggers(el::Level::Trace, el::ConfigurationType::Enabled, "false");
        }
        el::Loggers::reconfigureAllLoggers(el::ConfigurationType::PerformanceTracking, "false");
    }

    void TearDown() {
        SyncMem::clear_cache();
    }

    float_type train_exact(GBMParam &param) {
        DataSet dataSet;
        dataSet.load_from_file(param.path);
        int n_instances = dataSet.n_instances();
        vector<Tree> trees;
        trees.resize(param.n_trees);

        ExactUpdater updater(param);
        updater.init(dataSet);
        int round = 0;
        float_type rmse = 0;
        SyncMem::clear_cache();
        {
            TIMED_SCOPE(timerObj, "construct tree");
            for (Tree &tree:trees) {
                updater.grow(tree);
                LOG(DEBUG) << string_format("\nbooster[%d]", round) << tree.dump(param.depth);
                //next round
                round++;
                rmse = compute_rmse(updater.shards.front()->stats);
                LOG(INFO) << "rmse = " << rmse;
            }
        }
        return rmse;
    }

    float_type train_hist(GBMParam &param) {
        DataSet dataSet;
        dataSet.load_from_file(param.path);

        SyncMem::clear_cache();

        vector<vector<Tree>> trees;
        vector<HistUpdater::ShardT> shards(param.n_device);

        //TODO refactor these
        SparseColumns columns;
        columns.from_dataset(dataSet);
        vector<std::unique_ptr<SparseColumns>> v_columns(param.n_device);
        for (int i = 0; i < param.n_device; ++i) {
            v_columns[i].reset(&shards[i].columns);
        }
        columns.to_multi_devices(v_columns);

        HistUpdater updater(param);
        HistUpdater::for_each_shard(shards, [&](Shard &shard) {
            int n_instances = shard.columns.n_row;
            shard.stats.resize(n_instances);
            shard.stats.y.copy_from(dataSet.y.data(), n_instances);
            shard.stats.obj.reset(ObjectiveFunction::create(param.objective));
            shard.stats.obj->configure(param);
            shard.param = param;
            shard.param.learning_rate /= param.n_parallel_trees;//average trees in one iteration
        });
        updater.init(shards);

        SyncMem::clear_cache();

        int round = 0;
        float_type rmse = 0;
        {
            TIMED_SCOPE(timerObj, "construct tree");
            int n_instances = shards.front().stats.n_instances;
            SyncArray<GHPair> all_gh_pair(n_instances * param.num_class);
            SyncArray<float_type> all_y(n_instances * param.num_class);
            for (int iter = 0; iter < param.n_trees; iter++) {
                //one boosting iteration

                trees.emplace_back();
                vector<Tree> &tree = trees.back();
                tree.resize(param.n_parallel_trees);
                if (param.num_class == 1) {
                    //update gradient
                    HistUpdater::for_each_shard(shards, [&](Shard &shard) {
                        shard.stats.update_gradient();
                        if (updater.param.bagging) {
                            shard.stats.gh_pair_backup.resize(shard.stats.n_instances);
                            shard.stats.gh_pair_backup.copy_from(shard.stats.gh_pair);
                        }
                    });
                    updater.grow(tree, shards);

//                LOG(DEBUG) << string_format("\nbooster[%d]", round) << tree.dump(param.depth);

                    //next round
                    round++;
                    rmse = compute_rmse(shards.front().stats);
                    LOG(INFO) << "rmse = " << rmse;
                } else {
                    SyncArray<float_type> prob(all_y.size());
                    prob.copy_from(all_y);
                    shards.front().stats.obj->predict_transform(prob);
                    auto yp_data = prob.device_data();
                    auto y_data = shards.front().stats.y.device_data();
                    int num_class = param.num_class;
                    device_loop(n_instances, [=] __device__(int i){
                        int max_k = 0;
                        float_type max_p = yp_data[i];
                        for (int k = 1; k < num_class; ++k) {
                            if (yp_data[k * n_instances + i] > max_p) {
                                max_p = yp_data[k * n_instances + i];
                                max_k = k;
                            }
                        }
                        yp_data[i] = max_k == y_data[i];
                    });

                    float acc = thrust::reduce(thrust::cuda::par, yp_data, yp_data + n_instances) / n_instances;
                    LOG(INFO)<<"accuracy = " << acc;

                    shards.front().stats.obj->get_gradient(shards.front().stats.y, all_y, all_gh_pair);
                    for (int i = 0; i < param.num_class; ++i) {
                        trees.emplace_back();
                        vector<Tree> &tree = trees.back();
                        tree.resize(param.n_parallel_trees);
                        HistUpdater::for_each_shard(shards, [&](Shard &shard){
                            shard.stats.gh_pair.copy_from(all_gh_pair.device_data() + i * n_instances, n_instances);
                            shard.stats.y_predict.copy_from(all_y.device_data() + i * n_instances, n_instances);
                        });
                        updater.grow(tree, shards);
                        CUDA_CHECK(cudaMemcpy(all_y.device_data() + i * n_instances, shards.front().stats.y_predict.device_data(),
                                              sizeof(float_type) * n_instances, cudaMemcpyDefault));
                    }
                }
            }
        }
        for (int i = 0; i < param.n_device; ++i) {
            v_columns[i].release();
        }
        return rmse;
    }

    float_type compute_rmse(const InsStat &stats) {
        TIMED_FUNC(timerObj);
        SyncArray<float_type> sq_err(stats.n_instances);
        auto sq_err_data = sq_err.device_data();
        const float_type *y_data = stats.y.device_data();
        const float_type *y_predict_data = stats.y_predict.device_data();
        device_loop(stats.n_instances, [=]__device__(int i) {
            float_type e = y_predict_data[i] - y_data[i];
            sq_err_data[i] = e * e;
        });
        float_type rmse =
                sqrt(thrust::reduce(thrust::cuda::par, sq_err.device_data(), sq_err.device_end()) / stats.n_instances);
        return rmse;
    }

};

class Exact : public UpdaterTest {
};

class Hist : public UpdaterTest {
};

TEST_F(UpdaterTest, news20_40_trees_same_as_xgboost) {
    param.path = DATASET_DIR "news20.scale";
    float_type rmse = train_exact(param);//5375 ms
    EXPECT_NEAR(rmse, 2.55275, 1e-5);
}

TEST_F(UpdaterTest, abalone_40_trees_same_as_xgboost) {
    param.path = DATASET_DIR "abalone";
    float_type rmse = train_exact(param);//1674 ms
    EXPECT_NEAR(rmse, 0.803684, 1e-5);
}

TEST_F(UpdaterTest, iris) {
    param.n_trees = 2;
    param.path = DATASET_DIR "iris.scale";
    train_hist(param);
}

TEST_F(UpdaterTest, iris_exact) {
    param.n_trees = 2;
    param.path = DATASET_DIR "iris.scale";
    train_exact(param);
}

TEST_F(Exact, covtype) {
    param.path = DATASET_DIR "covtype";
    train_exact(param);
}

TEST_F(Exact, e2006) {
    param.path = DATASET_DIR "E2006.train";
    train_exact(param);
}

TEST_F(Exact, higgs) {
    param.path = DATASET_DIR "HIGGS";
    train_exact(param);
}

TEST_F(Exact, ins) {
    param.path = DATASET_DIR "ins.libsvm";
    train_exact(param);
}

TEST_F(Exact, log1p) {
    param.path = DATASET_DIR "log1p.E2006.train";
    train_exact(param);
}


TEST_F(Exact, news20) {
    param.path = DATASET_DIR "news20.binary";
    train_exact(param);
}

TEST_F(Exact, real_sim) {
    param.path = DATASET_DIR "real-sim";
    train_exact(param);
}

TEST_F(Exact, susy) {
    param.path = DATASET_DIR "SUSY";
    train_exact(param);
}

TEST_F(Hist, covtype) {
    param.path = DATASET_DIR "covtype";
    train_hist(param);
}

TEST_F(Hist, higgs) {
    param.path = DATASET_DIR "HIGGS";
    train_hist(param);
}

TEST_F(Hist, ins) {
    param.path = DATASET_DIR "ins.libsvm";
    train_hist(param);
}

TEST_F(Hist, susy) {
    param.path = DATASET_DIR "SUSY";
    train_hist(param);
}

TEST_F(Hist, any) {
    train_hist(param);
}
