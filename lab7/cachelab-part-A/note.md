cachelab的第一部分，是要求我们完成csim.c的书写。

首先查看pdf，我们可以知道，traces文件夹下面的内容是由valgrind生成的。格式类似为：
```
 S 00600aa0,1
I  004005b6,5
```

第一列的`I`表示的是加载指令。第二列可以是`L`、`S`和`M`，分别表示读取数据、写入数据、
修改数据。在这个这个部分，修改数据视作先读取数据，然后立即写入数据。第三列是64位的地
址，而第四位是访存的大小。

我们可以使用`csim-ref`程序来看看最后实现的效果是什么。

```text
Usage: ./csim-ref [-hv] -s <num> -E <num> -b <num> -t <file>
Options:
  -h         Print this help message.
  -v         Optional verbose flag.
  -s <num>   Number of set index bits.
  -E <num>   Number of lines per set.
  -b <num>   Number of block offset bits.
  -t <file>  Trace file.

Examples:
  linux>  ./csim-ref -s 4 -E 1 -b 4 -t traces/yi.trace
  linux>  ./csim-ref -v -s 8 -E 2 -b 4 -t traces/yi.trace
```

`-v`是显示详细内容，`-s <num>`表示组索引需要的bit数，也就是说`S=2^s`，`S`为组个数。
`-E <num>`是每组的行数，`-b <num>`是块位移所需的bit数，也就是说`B=2^b`，`B`为块的大
小。

```
$> ./csim-ref -s 4 -E 1 -b 4 -t traces/yi.trace
hits:4 misses:5 evictions:3

$> ./csim-ref -v -s 8 -E 2 -b 4 -t traces/yi.trace
L 10,1 miss
M 20,1 miss hit
L 22,1 hit
S 18,1 hit
L 110,1 miss
L 210,1 miss
M 12,1 hit hit
hits:5 misses:4 evictions:0
```

pdf还给了我们一些提示和要求：

1. 我们需要使用`malloc`来帮我们分配一块内存来模拟cache。
2. 我们仅仅关系数据cache的性能，所以我们的模拟器应当忽略指令的cache。此外，由于所有
   的`I`都是在第一列的，而其余的`L`、`S`和`M`都是在第二列，前面有一个空格，所以可以
   通过这种方式来区分。
3. 必须调用函数`printSummary`，参数为hit、miss和eviction的总数。
4. 假设内存访问都是对齐的，因此单次内存访问永远不会越过块的边界。在此假设下，可以忽
   略上面`valgrind`输出的访存的大小的参数。
5. 使用LRU的替换策略。


至此，我们开始写C语言程序。

首先分析一下它定义的数据结构：

```c
typedef struct cache_line {
    char valid;
    mem_addr_t tag;
    unsigned long long int lru;
} cache_line_t;
```

这个就是cache的一行。`vaild`自然就是这个cache行中的内容是否是有效的，`tag`则是指明缓
存的块，最后`lru`用于确定cache行的使用情况。

`lru`的计算方式和含义是：

1. 计数值越小就说明越被常用。
2. 命中时，被访问的行的计数器置`0`，比其低的计数器加`1`，其余不变。
3. 未命中且该组未满时，新行计数器置为`0`，其余全加`1`。
4. 未命中且该组已满时，计数值为`E-1`的那一行中的主存块被淘汰，新行计数器置为`0`，其
   余加`1`。

接着是`typedef cache_line_t* cache_set_t`。一个`cache_set_t`应当是一个`cache_line_t`
的数组，长度为`E`。

最后是`typedef cache_set_t* cache_t`。一个`cache_t`应当是一个`cache_set_t`的数组，长
度为`S`。

接着从`main`函数开始看起，`s`, `b`, `E`, `S`, `B`, `trace_file`已经帮我们设置好了。
然后直接调用了`initCache`。

`initCache`中，首先分配了长度为`S`的`cache_set_t`类型的数组`cache`，然后为数组中的每
个`cache_set_t`赋值为长度为`E`的`cache_line_t`，每个`cache_line_t`的`valid`为`0`,`tag`
为`0`，`lru`为`0`。

`set_index_mask`为`2^s-1`，当我们需要由地址得到组号索引时，只需要`(addr >> b) & set_index_mask`
即可。

接着`main`函数调用了`replayTrace`函数。其中大的while对文件进行逐行读取，存储在`buf`中。
若第二个字符为`L`、`S`或`M`，那么就读取其后的地址和长度，并分别存储在`addr`和`len`中。
然后调用`accessData`，参数为`addr`。如果为`M`，视作读并写，因此需要再次访问`addr`。

我们接下来就是要实现`accessData`。

我们现在是组相联映射，因此对于一个64位的addr，可以分成如下部分：

```
| 标记（长度为64-s-b） | 组索引（长度为s） | 块偏移（长度为b） |
```

首先要检查cache是否命中，步骤是先通过组索引找到相应的组，然后遍历组中的所有数据，检查
是否存在`tag`匹配。匹配则表示命中，否则，就执行不匹配的逻辑：

```c
unsigned long long set_index = (addr >> b) & set_index_mask;
unsigned long long tag = addr >> (b + s);
unsigned char is_hit = 0;

for (int i = 0; i < E; ++i) {
    // 检查组内的每一行，如果vaild且tag匹配，则为hit
    cache_line_t* current_line = &cache[set_index][i];
    if (current_line->valid && (current_line->tag == tag)) {
        ++hit_count;
        // 更新lru，规则为被访问的行的lru置0，比其低的lru加1
        unsigned long long old_lru = current_line->lru;
        for (int j = 0; j < E; ++j) {
            cache_line_t* update_line = &cache[set_index][j];
            if (update_line->valid && update_line->lru < old_lru) {
                ++(update_line->lru);
            }
        }
        current_line->lru = 0;
        is_hit = 1;
        break;
    }
}

// 未命中
if (!is_hit) {
    // ...
}
```

上述就是一个判断命中的逻辑了。

接下来我们解决未命中且该组未满时的情况，策略很简单，只需要遍历，并记录下未满的组的索
引即可：

```c
// --snip--

// 未命中
if (!is_hit) {
    // 处理组未满的情况的变量
    unsigned long long empty_line_index = 0;
    unsigned char has_empty_line = 0;

    ++miss_count;

    for (int i = 0; i < E; ++i) {
        cache_line_t* current_line = &cache[set_index][i];
        if (!current_line->valid) {
            // 组未满，并获取具体行
            has_empty_line = 1;
            empty_line_index = i;
            break;
        }

        // ...
    }

    // 处理组未满的情况
    if (has_empty_line) {
        cache_line_t* empty_line = &cache[set_index][empty_line_index];
        // 更新lru，规则为新行lru置0，其余加1
        empty_line->lru = 0;
        for (int i = 0; i < E; ++i) {
            cache_line_t* update_line = &cache[set_index][i];
            if (update_line->valid) {
                ++(update_line->lru);
            }
        }

        empty_line->valid = 1;
        empty_line->tag = tag;
    }
    else {
        // ...
    }
}
```

最后是未命中且组已满的情况，由于是lru策略，所以只要找到lru值最大的元素，就表明是最近
最少使用的元素，记录下其索引，作为被牺牲的行即可：

```c
// 未命中
if (!is_hit) {
    // 处理组未满的情况的变量
    unsigned long long empty_line_index = 0;
    unsigned char has_empty_line = 0;

    // 处理组已满的情况的变量
    unsigned long long max_lru_index = 0;
    unsigned long long max_lru_value = 0;

    ++miss_count;

    for (int i = 0; i < E; ++i) {
        cache_line_t* current_line = &cache[set_index][i];
        if (!current_line->valid) {
            // --snip--
        }

        // 获取lru最大的行，此处必然是current_line->valid的
        if (current_line->lru > max_lru_value) {
            max_lru_value = current_line->lru;
            max_lru_index = i;
        }
    }

    // 处理组未满的情况
    if (has_empty_line) {
        // --snip--
    }
    else {  // 处理组已满的情况
        cache_line_t* evict_line = &cache[set_index][max_lru_index];
        ++eviction_count;
        // 更新lru，规则为新行lru置0，其余加1
        for (int i = 0; i < E; ++i) {
            cache_line_t* update_line = &cache[set_index][i];
            // 组已满，所有行均valid
            ++(update_line->lru);
        }

        evict_line->lru = 0;
        evict_line->tag = tag;
    }
}
```

大功告成。完整的`accessData`函数如下：

```c
/* 
 * accessData - Access data at memory address addr.
 *   If it is already in cache, increast hit_count
 *   If it is not in cache, bring it in cache, increase miss count.
 *   Also increase eviction_count if a line is evicted.
 */
void accessData(mem_addr_t addr)
{
    unsigned long long set_index = (addr >> b) & set_index_mask;
    unsigned long long tag = addr >> (b + s);
    unsigned char is_hit = 0;

    for (int i = 0; i < E; ++i) {
        // 检查组内的每一行，如果vaild且tag匹配，则为hit
        cache_line_t* current_line = &cache[set_index][i];
        if (current_line->valid && (current_line->tag == tag)) {
            ++hit_count;
            // 更新lru，规则为被访问的行的lru置0，比其低的lru加1
            unsigned long long old_lru = current_line->lru;
            for (int j = 0; j < E; ++j) {
                cache_line_t* update_line = &cache[set_index][j];
                if (update_line->valid && update_line->lru < old_lru) {
                    ++(update_line->lru);
                }
            }
            current_line->lru = 0;
            is_hit = 1;
            break;
        }
    }

    // 未命中
    if (!is_hit) {
        // 处理组未满的情况的变量
        unsigned long long empty_line_index = 0;
        unsigned char has_empty_line = 0;

        // 处理组已满的情况的变量
        unsigned long long max_lru_index = 0;
        unsigned long long max_lru_value = 0;

        ++miss_count;

        for (int i = 0; i < E; ++i) {
            cache_line_t* current_line = &cache[set_index][i];
            if (!current_line->valid) {
                // 组未满，并获取具体行
                has_empty_line = 1;
                empty_line_index = i;
                break;
            }

            // 获取lru最大的行，此处必然是current_line->valid的
            if (current_line->lru > max_lru_value) {
                max_lru_value = current_line->lru;
                max_lru_index = i;
            }
        }

        // 处理组未满的情况
        if (has_empty_line) {
            cache_line_t* empty_line = &cache[set_index][empty_line_index];
            // 更新lru，规则为新行lru置0，其余加1
            empty_line->lru = 0;
            for (int i = 0; i < E; ++i) {
                cache_line_t* update_line = &cache[set_index][i];
                if (update_line->valid) {
                    ++(update_line->lru);
                }
            }

            empty_line->valid = 1;
            empty_line->tag = tag;
        }
        else {  // 处理组已满的情况
            cache_line_t* evict_line = &cache[set_index][max_lru_index];
            ++eviction_count;
            // 更新lru，规则为新行lru置0，其余加1
            for (int i = 0; i < E; ++i) {
                cache_line_t* update_line = &cache[set_index][i];
                // 组已满，所有行均valid
                ++(update_line->lru);
            }

            evict_line->lru = 0;
            evict_line->tag = tag;
        }
    }
}
```

接下来`main`函数中的`freeCache`调用和`printSummary`调用自不必多说。

接下来编译一下我们写的代码吧：

```
$> make clean
rm -rf *.o
rm -f *.tar
rm -f csim
rm -f test-trans tracegen
rm -f trace.all trace.f*
rm -f .csim_results .marker

$> make
gcc -g -Wall -Werror -std=c99 -m64 -o csim csim.c cachelab.c -lm
gcc -g -Wall -Werror -std=c99 -m64 -O0 -c trans.c
gcc -g -Wall -Werror -std=c99 -m64 -o test-trans test-trans.c cachelab.c trans.o
gcc -g -Wall -Werror -std=c99 -m64 -O0 -o tracegen tracegen.c trans.o cachelab.c
# Generate a handin tar file each time you compile
tar -cvf c163q-handin.tar  csim.c trans.c
csim.c
trans.c
```

然后测试一下：

```shell
./test-csim
```

测试结果：

```
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

TEST_CSIM_RESULTS=27
```

我们的模拟器的结果和参考模拟器的结果完全一致。

值得注意的是，实验报告中要求我们手算一个结果，验证正确性。此处，我们使用：

```
$> ./csim -s 4 -E 1 -b 4 -t traces/yi.trace
hits:4 misses:5 evictions:3
```

`yi.trace`的内容如下：

```
 L 10,1
 M 20,1
 L 22,1
 S 18,1
 L 110,1
 L 210,1
 M 12,1
```

给定一个地址，对于上述cache来说，可以分为：

```
| 标记(56bits) | 组索引(4bits) | 块偏移(4bits) |
```

每组只有一行，所以相当于是直接映射。

为了方便说明cache的内容，使用`(x, y)`表示某个cache行中`tag`为`x`，组索引为`y`。

- `L 10,1`，标记为0，组索引为1，所以miss。此时cache中的内容为`[(0, 1)]`，且
  `hits: 0, misses: 1, evictions: 0`
- `M 20,1`，这是读并写的操作，相当于accessData两次。
    - 标记为0，组索引为2，所以miss。此时cache中的内容为`[(0, 1), (0, 2)]`，且
      `hits: 0, misses: 2, evictions: 0`
    - 标记为0，组索引为2，所以hit。此时cache中的内容为`[(0, 1), (0, 2)]`，且
      `hits: 1, misses: 2, evictions: 0`
- `L 22,1`，标记为0，组索引为2，所以hit。此时cache中的内容为`[(0, 1), (0, 2)]`，且
  `hits: 2, misses: 2, evictions: 0`
- `S 18,1`，标记为0，组索引为1，所以hit。此时cache中的内容为`[(0, 1), (0, 2)]`，且
  `hits: 3, misses: 2, evictions: 0`
- `L 110,1`，标记为1，组索引为1，所以miss且需要替换。此时cache中的内容为`[(1, 1), (0, 2)]`，
  且`hits: 3, misses: 3, evictions: 1`
- `L 210,1`，标记为2，组索引为1，所以miss且需要替换。此时cache中的内容为`[(2, 1), (0, 2)]`，
  且`hits: 3, misses: 4, evictions: 2`
- `M 12,1`，这是读并写的操作，相当于accessData两次。
    - 标记为0，组索引为1，所以miss且需要替换。此时cache中的内容为`[(0, 1), (0, 2)]`，
      且`hits: 3, misses: 5, evictions: 3`
    - 标记为0，组索引为1，所以hit。此时cache中的内容为`[(0, 1), (0, 2)]`，且
      `hits: 4, misses: 5, evictions: 3`

手工计算的结果为`hits: 4, misses: 5, evictions: 3`，与程序输出的是一致的。

