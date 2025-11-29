这次要求我们完成`trans.c`文件里面的矩阵转置函数，并且要求cache的miss数越少越好。
此外，还有一些额外的限制：

1. 转置函数最多使用12个`int`类型的局部变量。
2. 不允许使用`long`类型或者通过位运算的方法在一个变量中存储多个值以绕过第一条的限制。
3. 转置函数不应当使用递归。
4. 如果使用helper函数，则helper函数和顶部函数的局部变量数的总和不应该超过12个。
5. 转置函数不应当修改矩阵A。
6. 不能在代码中定义任何数组或使用任何`malloc`函数及其变体。

矩阵转置函数评测的矩阵大小及其miss次数要求为：

| 大小 | 最大miss次数 |
| ---- | ------------ |
| 32×32 | 300 |
| 64×64 | 1300 |
| 61×67 | 2000 |

在评测的时候，使用的cache的参数为`s = 5, E = 1, b = 5`。

现在暂时还是一头雾水，所以不妨先试一试最最简单的矩阵转置算法的效果：

```c
void transpose_submit(int M, int N, int A[N][M], int B[M][N])
{
    for (int i = 0; i < N; ++i) {
        for (int j = 0; j < M; ++j) {
            B[j][i] = A[i][j];
        }
    }
}
```

跑一下三个大小：

```
$> ./test-trans -M 32 -N 32

Function 0 (2 total)
Step 1: Validating and generating memory traces
Step 2: Evaluating performance (s=5, E=1, b=5)
func 0 (Transpose submission): hits:869, misses:1184, evictions:1152

$> ./test-trans -M 64 -N 64

Function 0 (2 total)
Step 1: Validating and generating memory traces
Step 2: Evaluating performance (s=5, E=1, b=5)
func 0 (Transpose submission): hits:3473, misses:4724, evictions:4692

$> ./test-trans -M 61 -N 67

Function 0 (2 total)
Step 1: Validating and generating memory traces
Step 2: Evaluating performance (s=5, E=1, b=5)
func 0 (Transpose submission): hits:3755, misses:4424, evictions:4392
```

看起来非常不理想。

我们首先来分析一下cache，测评时使用的是直接映射的方法，一共有32个cache行，每行32bytes。
而在x86-64下，`int`是4bytes的，所以说一个cache行应该能够缓存连续的8个`int`。

然而可惜的是，对于矩阵A连续的8个元素对于矩阵B来说是不连续的，且不会存储在相同的cache行中。

那不妨这样，我们把一整个矩阵分隔成多个8×8的小矩阵，对于矩阵A来说，每一行都放在同一个cache行中，
所以miss数不会很大。

而对于矩阵B来说，我们是按列访问的，但是由于每次进行拷贝时，仅仅只有8行的跨度，
因此应该不会导致先前在cache的元素被替换掉。我们先仅考虑32×32的矩阵，这个矩阵一行32个元素，
所以元素`(0, 0)`和元素`(1, 0)`应该在`i`和`(i+4)%32`的cache行，我们一共有32个cache行，
而在这种方式下最多只会访问到`(i+28)%32`的cache行，显然不会导致替换。

对于A，由于我们要按行访问矩阵A分出的8×8小矩阵的每一列，且总列数正好是8，所以cache应该可以很好的hit。

我们来实现一下：
```c
void transpose_submit(int M, int N, int A[N][M], int B[M][N])
{
    for (int i = 0; i < N; i += 8) {
        for (int j = 0; j < M; j += 8) {
            for (int k = i; k < i + 8 && k < N; ++k) {
                for (int l = j; l < j + 8 && l < M; ++l) {
                    B[l][k] = A[k][l];
                }
            }
        }
    }
}
```

测试一下：
```c
$> ./test-trans -M 32 -N 32

Function 0 (2 total)
Step 1: Validating and generating memory traces
Step 2: Evaluating performance (s=5, E=1, b=5)
func 0 (Transpose submission): hits:1709, misses:344, evictions:312

Function 1 (2 total)
Step 1: Validating and generating memory traces
Step 2: Evaluating performance (s=5, E=1, b=5)
func 1 (Simple row-wise scan transpose): hits:869, misses:1184, evictions:1152

Summary for official submission (func 0): correctness=1 misses=344

TEST_TRANS_RESULTS=1:344

$> ./test-trans -M 64 -N 64

Function 0 (2 total)
Step 1: Validating and generating memory traces
Step 2: Evaluating performance (s=5, E=1, b=5)
func 0 (Transpose submission): hits:3473, misses:4724, evictions:4692

Function 1 (2 total)
Step 1: Validating and generating memory traces
Step 2: Evaluating performance (s=5, E=1, b=5)
func 1 (Simple row-wise scan transpose): hits:3473, misses:4724, evictions:4692

Summary for official submission (func 0): correctness=1 misses=4724

TEST_TRANS_RESULTS=1:4724

$> ./test-trans -M 61 -N 67

Function 0 (2 total)
Step 1: Validating and generating memory traces
Step 2: Evaluating performance (s=5, E=1, b=5)
func 0 (Transpose submission): hits:6060, misses:2119, evictions:2087

Function 1 (2 total)
Step 1: Validating and generating memory traces
Step 2: Evaluating performance (s=5, E=1, b=5)
func 1 (Simple row-wise scan transpose): hits:3755, misses:4424, evictions:4392

Summary for official submission (func 0): correctness=1 misses=2119

TEST_TRANS_RESULTS=1:2119
```

32×32和61×67确实有很大的提升，并且已经接近我们的要求了，但是64×64却没有任何改善。

我们先聚焦于64×64的问题。没有改善的原因是矩阵一行有64个元素，也就是说，上下两个之间
会相差8个cache行，因此当我们访问了矩阵A的`(0, 0) - (0, 3)`元素并复制到矩阵B的`(0, 0) - (3, 0)`
之后，当我访问了矩阵A的`(0, 4)`并复制到矩阵B的`(4, 0)`时，会替换`(0, 0)`所在的cache行。
在这种情况下，我们会发现对矩阵B的cache完全没有意义！

如何解决这个问题？我们只要在64×64时分割为4×4即可。

```c
void transpose_submit(int M, int N, int A[N][M], int B[M][N])
{
    int i, j, k, l, tmp;
    int n = (M == 64 ? 4 : 8);
    for (i = 0; i < N; i += n) {
        for (j = 0; j < M; j += n) {
            for (k = i; k < i + n && k < N; ++k) {
                for (l = j; l < j + n && l < M; ++l) {
                    tmp = A[k][l];
                    B[l][k] = tmp;
                }
            }
        }
    }
}
```

这里，为了方便记录用了多少变量，所以所有变量的定义都放在了函数开头。

测试一下：

```
$> ./test-trans -M 64 -N 64

Function 0 (2 total)
Step 1: Validating and generating memory traces
Step 2: Evaluating performance (s=5, E=1, b=5)
func 0 (Transpose submission): hits:6305, misses:1892, evictions:1860

Summary for official submission (func 0): correctness=1 misses=1892

TEST_TRANS_RESULTS=1:1892
```

还是有点不太理想，因为32×32和61×67都已经非常接近最后的要求了，但64×64还是差很多。
我们再次思考一下还能如何优化。

我们假设这样的一个需要转置的64×64矩阵的其中两个8×8区域：

```
             1234 1234
            ┌────┬────┐
            │    │    │1
            │ 1  │ 2  │2
            │    │    │3
            │    │    │4
            ├────┼────┤  矩阵A一部分
            │    │    │1
            │ 3  │ 4  │2
            │    │    │3
            │    │    │4
            └────┴────┘
 1234 1234
┌────┬────┐
│    │    │1
│ 1  │ 2  │2
│    │    │3
│    │    │4
├────┼────┤  矩阵B一部分
│    │    │1
│ 3  │ 4  │2
│    │    │3
│    │    │4
└────┴────┘
```

我们在上面已经将其进一步分为4×4的小块了，我们先将1转置到1（将上图矩阵A的第1个4×4的部分转置，
并放到矩阵B的第1个4×4的部分），2转置到3，然后经过其他转置之后将3转置到2，将4转置到4。
但问题是，一个cache行能存8个元素，如果我们这么做，对于矩阵A能很好地利用8个cache元素，
但矩阵B不行，只能利用其中4个。我们能不能进一步优化？

我们看一下矩阵B的8×8的子矩阵中区域3和区域4部分，如果处理完3之后立即处理矩阵4部分，
就能很好了利用处理3时存入cache的内容了，我们也不必担心这种操作对矩阵A的cache命中率的影响，
因为处理A的4时，替换的cache内容是1和2的部分，而这部分我们已经处理过了，可以放心替换。
最后再处理B中2的部分，这样对于矩阵A，也可以利用处理第4部分时cache中的内容。

我们这样修改代码：

```c
void transpose_submit(int M, int N, int A[N][M], int B[M][N])
{
    int i, j, k, l, tmp;
    if (M != 64) {
        for (i = 0; i < N; i += 8) {
            for (j = 0; j < M; j += 8) {
                for (k = i; k < i + 8 && k < N; ++k) {
                    for (l = j; l < j + 8 && l < M; ++l) {
                        tmp = A[k][l];
                        B[l][k] = tmp;
                    }
                }
            }
        }
    } else {
        for (i = 0; i < N; i += 8) {
            for (j = 0; j < M; j += 8) {
                for (k = i; k < i + 4; ++k) {
                    for (l = j; l < j + 4; ++l) {
                        tmp = A[k][l];
                        B[l][k] = tmp;
                    }
                }
                for (k = i; k < i + 4; ++k) {
                    for (l = j + 4; l < j + 8; ++l) {
                        tmp = A[k][l];
                        B[l][k] = tmp;
                    }
                }
                for (k = i + 4; k < i + 8; ++k) {
                    for (l = j + 4; l < j + 8; ++l) {
                        tmp = A[k][l];
                        B[l][k] = tmp;
                    }
                }
                for (k = i + 4; k < i + 8; ++k) {
                    for (l = j; l < j + 4; ++l) {
                        tmp = A[k][l];
                        B[l][k] = tmp;
                    }
                }
            }
        }
    }
}
```

测试一下：

```
$> ./test-trans -M 64 -N 64

Function 0 (2 total)
Step 1: Validating and generating memory traces
Step 2: Evaluating performance (s=5, E=1, b=5)
func 0 (Transpose submission): hits:6553, misses:1644, evictions:1612

Summary for official submission (func 0): correctness=1 misses=1644

TEST_TRANS_RESULTS=1:1644
```

比之前好了点。

但我们现在始终没有任何一个大小的矩阵达到我们的要求。可以尝试的一个点是循环展开，
然后定义一系列临时变量，先将矩阵A中连续的元素赋值给临时变量，接着再将临时变量赋值给B中的。
这么做的原因是，矩阵A与矩阵B很有可能会争用cache行，这种情况下，使用这种方式可以避免一些
这样的情况。

修改代码，如下：

```c
void transpose_submit(int M, int N, int A[N][M], int B[M][N])
{
    int tmp1, tmp2, tmp3, tmp4, tmp5, tmp6, tmp7, tmp8;
    int i, j, k;
    if (M == 32) {
        for (i = 0; i < N; i += 8) {
            for (j = 0; j < M; j += 8) {
                for (k = i; k < i + 8; ++k) {
                    tmp1 = A[k][j];
                    tmp2 = A[k][j + 1];
                    tmp3 = A[k][j + 2];
                    tmp4 = A[k][j + 3];
                    tmp5 = A[k][j + 4];
                    tmp6 = A[k][j + 5];
                    tmp7 = A[k][j + 6];
                    tmp8 = A[k][j + 7];

                    B[j][k] = tmp1;
                    B[j + 1][k] = tmp2;
                    B[j + 2][k] = tmp3;
                    B[j + 3][k] = tmp4;
                    B[j + 4][k] = tmp5;
                    B[j + 5][k] = tmp6;
                    B[j + 6][k] = tmp7;
                    B[j + 7][k] = tmp8;
                }
            }
        }
    } else if (M == 64) {
        for (i = 0; i < N; i += 8) {
            for (j = 0; j < M; j += 8) {
                for (k = i; k < i + 4; ++k) {
                    tmp1 = A[k][j];
                    tmp2 = A[k][j + 1];
                    tmp3 = A[k][j + 2];
                    tmp4 = A[k][j + 3];

                    B[j][k] = tmp1;
                    B[j + 1][k] = tmp2;
                    B[j + 2][k] = tmp3;
                    B[j + 3][k] = tmp4;
                }
                for (k = i; k < i + 4; ++k) {
                    tmp5 = A[k][j + 4];
                    tmp6 = A[k][j + 5];
                    tmp7 = A[k][j + 6];
                    tmp8 = A[k][j + 7];

                    B[j + 4][k] = tmp5;
                    B[j + 5][k] = tmp6;
                    B[j + 6][k] = tmp7;
                    B[j + 7][k] = tmp8;
                }
                for (k = i + 4; k < i + 8; ++k) {
                    tmp1 = A[k][j + 4];
                    tmp2 = A[k][j + 5];
                    tmp3 = A[k][j + 6];
                    tmp4 = A[k][j + 7];

                    B[j + 4][k] = tmp1;
                    B[j + 5][k] = tmp2;
                    B[j + 6][k] = tmp3;
                    B[j + 7][k] = tmp4;
                }
                for (k = i + 4; k < i + 8; ++k) {
                    tmp5 = A[k][j];
                    tmp6 = A[k][j + 1];
                    tmp7 = A[k][j + 2];
                    tmp8 = A[k][j + 3];

                    B[j][k] = tmp5;
                    B[j + 1][k] = tmp6;
                    B[j + 2][k] = tmp7;
                    B[j + 3][k] = tmp8;
                }
            }
        }
    } else {
        for (i = 0; i < N; i += 8) {
            for (j = 0; j < M; j += 8) {
                for (k = i; k < i + 8 && k < N; ++k) {
                    if (j + 8 > M) {
                        tmp1 = A[k][j];
                        tmp2 = A[k][j + 1];
                        tmp3 = A[k][j + 2];
                        tmp4 = A[k][j + 3];
                        tmp5 = A[k][j + 4];

                        B[j][k] = tmp1;
                        B[j + 1][k] = tmp2;
                        B[j + 2][k] = tmp3;
                        B[j + 3][k] = tmp4;
                        B[j + 4][k] = tmp5;

                        continue;
                    }
                    tmp1 = A[k][j];
                    tmp2 = A[k][j + 1];
                    tmp3 = A[k][j + 2];
                    tmp4 = A[k][j + 3];
                    tmp5 = A[k][j + 4];
                    tmp6 = A[k][j + 5];
                    tmp7 = A[k][j + 6];
                    tmp8 = A[k][j + 7];

                    B[j][k] = tmp1;
                    B[j + 1][k] = tmp2;
                    B[j + 2][k] = tmp3;
                    B[j + 3][k] = tmp4;
                    B[j + 4][k] = tmp5;
                    B[j + 5][k] = tmp6;
                    B[j + 6][k] = tmp7;
                    B[j + 7][k] = tmp8;
                }
            }
        }
    }
}
```

这里我们使用了11个`int`类型的局部变量，比限制的12个少一个。

我们测试一下：

```
$> ./test-trans -M 32 -N 32

Function 0 (2 total)
Step 1: Validating and generating memory traces
Step 2: Evaluating performance (s=5, E=1, b=5)
func 0 (Transpose submission): hits:1765, misses:288, evictions:256

Summary for official submission (func 0): correctness=1 misses=288

TEST_TRANS_RESULTS=1:288

$> ./test-trans -M 64 -N 64

Function 0 (2 total)
Step 1: Validating and generating memory traces
Step 2: Evaluating performance (s=5, E=1, b=5)
func 0 (Transpose submission): hits:6745, misses:1452, evictions:1420

Summary for official submission (func 0): correctness=1 misses=1452

TEST_TRANS_RESULTS=1:1452

$> ./test-trans -M 61 -N 67

Function 0 (2 total)
Step 1: Validating and generating memory traces
Step 2: Evaluating performance (s=5, E=1, b=5)
func 0 (Transpose submission): hits:6181, misses:1998, evictions:1966

Summary for official submission (func 0): correctness=1 misses=1998

TEST_TRANS_RESULTS=1:1998
```

32×32的已经完全过关了，61×67的也擦线过，但64×64的仍然还是超过了要求的miss次数限制。

还是拿出那张图：

```
             1234 1234
            ┌────┬────┐
            │    │    │1
            │ 1  │ 2  │2
            │    │    │3
            │    │    │4
            ├────┼────┤  矩阵A一部分
            │    │    │1
            │ 3  │ 4  │2
            │    │    │3
            │    │    │4
            └────┴────┘
 1234 1234
┌────┬────┐
│    │    │1
│ 1  │ 2  │2
│    │    │3
│    │    │4
├────┼────┤  矩阵B一部分
│    │    │1
│ 3  │ 4  │2
│    │    │3
│    │    │4
└────┴────┘
```

我们思考一下究竟还有什么地方可以改进。首先，对于将1转置到1，矩阵B没有充分利用cache行，
仅利用了cache行中的4个`int`。对于3转置到2也是如此。

由于我们现在可以使用8个`tmp`局部变量了，因此，为了提高将1转置到1时cache的利用率，
我们将2转置到3时的结果不放到3，而是放到2，这样，就可以充分利用访问B中1时缓存的内容了。
然后直接将3转置到2，而2中原本的内容放到`tmp`中即可，待一行访问完毕再从`tmp`放到B的3中。
值得注意的是，此处的A的第3部分必须纵向遍历，因为B中第2部分的其余行的cache不能被替换。
此时B的3就被cache了，接下来将4转置到4时，也能够hit。

我们修改一下原来的代码：

```c
void transpose_submit(int M, int N, int A[N][M], int B[M][N])
{
    int tmp1, tmp2, tmp3, tmp4, tmp5, tmp6, tmp7, tmp8;
    int i, j, k;
    if (M == 32) {
        // --snip--
    } else if (M == 64) {
        for (i = 0; i < N; i += 8) {
            for (j = 0; j < M; j += 8) {
                for (k = i; k < i + 4; ++k) {
                    tmp1 = A[k][j];
                    tmp2 = A[k][j + 1];
                    tmp3 = A[k][j + 2];
                    tmp4 = A[k][j + 3];
                    tmp5 = A[k][j + 4];
                    tmp6 = A[k][j + 5];
                    tmp7 = A[k][j + 6];
                    tmp8 = A[k][j + 7];

                    B[j][k] = tmp1;
                    B[j + 1][k] = tmp2;
                    B[j + 2][k] = tmp3;
                    B[j + 3][k] = tmp4;
                    B[j][k + 4] = tmp5;
                    B[j + 1][k + 4] = tmp6;
                    B[j + 2][k + 4] = tmp7;
                    B[j + 3][k + 4] = tmp8;
                }
                for (k = j; k < j + 4; ++k) {
                    tmp1 = A[i + 4][k];
                    tmp2 = A[i + 5][k];
                    tmp3 = A[i + 6][k];
                    tmp4 = A[i + 7][k];
                    tmp5 = B[k][i + 4];
                    tmp6 = B[k][i + 5];
                    tmp7 = B[k][i + 6];
                    tmp8 = B[k][i + 7];

                    B[k][i + 4] = tmp1;
                    B[k][i + 5] = tmp2;
                    B[k][i + 6] = tmp3;
                    B[k][i + 7] = tmp4;
                    B[k + 4][i] = tmp5;
                    B[k + 4][i + 1] = tmp6;
                    B[k + 4][i + 2] = tmp7;
                    B[k + 4][i + 3] = tmp8;
                }
                for (k = i + 4; k < i + 8; ++k) {
                    tmp1 = A[k][j + 4];
                    tmp2 = A[k][j + 5];
                    tmp3 = A[k][j + 6];
                    tmp4 = A[k][j + 7];

                    B[j + 4][k] = tmp1;
                    B[j + 5][k] = tmp2;
                    B[j + 6][k] = tmp3;
                    B[j + 7][k] = tmp4;
                }
            }
        }
    } else {
        // --snip--
    }
}
```

测试一下：

```
$> ./test-trans -M 64 -N 64

Function 0 (2 total)
Step 1: Validating and generating memory traces
Step 2: Evaluating performance (s=5, E=1, b=5)
func 0 (Transpose submission): hits:9065, misses:1180, evictions:1148

Summary for official submission (func 0): correctness=1 misses=1180

TEST_TRANS_RESULTS=1:1180
```

达到要求了。

最后的代码如下：

```c
/* 
 * transpose_submit - This is the solution transpose function that you
 *     will be graded on for Part B of the assignment. Do not change
 *     the description string "Transpose submission", as the driver
 *     searches for that string to identify the transpose function to
 *     be graded. 
 */
char transpose_submit_desc[] = "Transpose submission";
void transpose_submit(int M, int N, int A[N][M], int B[M][N])
{
    int tmp1, tmp2, tmp3, tmp4, tmp5, tmp6, tmp7, tmp8;
    int i, j, k;
    if (M == 32) {
        for (i = 0; i < N; i += 8) {
            for (j = 0; j < M; j += 8) {
                for (k = i; k < i + 8; ++k) {
                    tmp1 = A[k][j];
                    tmp2 = A[k][j + 1];
                    tmp3 = A[k][j + 2];
                    tmp4 = A[k][j + 3];
                    tmp5 = A[k][j + 4];
                    tmp6 = A[k][j + 5];
                    tmp7 = A[k][j + 6];
                    tmp8 = A[k][j + 7];

                    B[j][k] = tmp1;
                    B[j + 1][k] = tmp2;
                    B[j + 2][k] = tmp3;
                    B[j + 3][k] = tmp4;
                    B[j + 4][k] = tmp5;
                    B[j + 5][k] = tmp6;
                    B[j + 6][k] = tmp7;
                    B[j + 7][k] = tmp8;
                }
            }
        }
    } else if (M == 64) {
        for (i = 0; i < N; i += 8) {
            for (j = 0; j < M; j += 8) {
                for (k = i; k < i + 4; ++k) {
                    tmp1 = A[k][j];
                    tmp2 = A[k][j + 1];
                    tmp3 = A[k][j + 2];
                    tmp4 = A[k][j + 3];
                    tmp5 = A[k][j + 4];
                    tmp6 = A[k][j + 5];
                    tmp7 = A[k][j + 6];
                    tmp8 = A[k][j + 7];

                    B[j][k] = tmp1;
                    B[j + 1][k] = tmp2;
                    B[j + 2][k] = tmp3;
                    B[j + 3][k] = tmp4;
                    B[j][k + 4] = tmp5;
                    B[j + 1][k + 4] = tmp6;
                    B[j + 2][k + 4] = tmp7;
                    B[j + 3][k + 4] = tmp8;
                }
                for (k = j; k < j + 4; ++k) {
                    tmp1 = A[i + 4][k];
                    tmp2 = A[i + 5][k];
                    tmp3 = A[i + 6][k];
                    tmp4 = A[i + 7][k];
                    tmp5 = B[k][i + 4];
                    tmp6 = B[k][i + 5];
                    tmp7 = B[k][i + 6];
                    tmp8 = B[k][i + 7];

                    B[k][i + 4] = tmp1;
                    B[k][i + 5] = tmp2;
                    B[k][i + 6] = tmp3;
                    B[k][i + 7] = tmp4;
                    B[k + 4][i] = tmp5;
                    B[k + 4][i + 1] = tmp6;
                    B[k + 4][i + 2] = tmp7;
                    B[k + 4][i + 3] = tmp8;
                }
                for (k = i + 4; k < i + 8; ++k) {
                    tmp1 = A[k][j + 4];
                    tmp2 = A[k][j + 5];
                    tmp3 = A[k][j + 6];
                    tmp4 = A[k][j + 7];

                    B[j + 4][k] = tmp1;
                    B[j + 5][k] = tmp2;
                    B[j + 6][k] = tmp3;
                    B[j + 7][k] = tmp4;
                }
            }
        }
    } else {
        for (i = 0; i < N; i += 8) {
            for (j = 0; j < M; j += 8) {
                for (k = i; k < i + 8 && k < N; ++k) {
                    if (j + 8 > M) {
                        tmp1 = A[k][j];
                        tmp2 = A[k][j + 1];
                        tmp3 = A[k][j + 2];
                        tmp4 = A[k][j + 3];
                        tmp5 = A[k][j + 4];

                        B[j][k] = tmp1;
                        B[j + 1][k] = tmp2;
                        B[j + 2][k] = tmp3;
                        B[j + 3][k] = tmp4;
                        B[j + 4][k] = tmp5;

                        continue;
                    }
                    tmp1 = A[k][j];
                    tmp2 = A[k][j + 1];
                    tmp3 = A[k][j + 2];
                    tmp4 = A[k][j + 3];
                    tmp5 = A[k][j + 4];
                    tmp6 = A[k][j + 5];
                    tmp7 = A[k][j + 6];
                    tmp8 = A[k][j + 7];

                    B[j][k] = tmp1;
                    B[j + 1][k] = tmp2;
                    B[j + 2][k] = tmp3;
                    B[j + 3][k] = tmp4;
                    B[j + 4][k] = tmp5;
                    B[j + 5][k] = tmp6;
                    B[j + 6][k] = tmp7;
                    B[j + 7][k] = tmp8;
                }
            }
        }
    }
}
```

最后跑一下测试：

```
$> pyenv local 2
$> python --version
Python 2.7.18
$> python ./driver.py
Part A: Testing cache simulator
Running ./test-csim
                        Your simulator     Reference simulator
Points (s,E,b)    Hits  Misses  Evicts    Hits  Misses  Evicts
     3 (1,1,1)       9       8       6       9       8       6  traces/yi2.trace
     3 (4,2,4)       4       5       2       4       5       2  traces/yi.trace
     3 (2,1,4)       2       3       1       2       3       1  traces/dave.trace
     3 (2,1,3)     167      71      67     167      71      67  traces/trans.trace
     3 (2,2,3)     201      37      29     201      37      29  traces/trans.trace
     3 (2,4,3)     212      26      10     212      26      10  traces/trans.trace
     3 (5,1,5)     231       7       0     231       7       0  traces/trans.trace
     6 (5,1,5)  265189   21775   21743  265189   21775   21743  traces/long.trace
    27


Part B: Testing transpose function
Running ./test-trans -M 32 -N 32
Running ./test-trans -M 64 -N 64
Running ./test-trans -M 61 -N 67

Cache Lab summary:
                        Points   Max pts      Misses
Csim correctness          27.0        27
Trans perf 32x32           8.0         8         288
Trans perf 64x64           8.0         8        1180
Trans perf 61x67          10.0        10        1998
          Total points    53.0        53
```

看起来是正确的。

