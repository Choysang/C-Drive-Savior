import { createApp, ref, onMounted } from 'https://unpkg.com/vue@3/dist/vue.esm-browser.js';

createApp({
    setup() {
        const loading = ref(false);
        const processingPath = ref(null);
        const currentTab = ref('assets');
        const overview = ref({
            c_drive: { free_gb: 0, total_gb: 0, used_gb: 0, used_percent: 0, fs: 'NTFS' },
            d_drive: { free_gb: 0, total_gb: 0, used_gb: 0, used_percent: 0, fs: 'NTFS' }
        });
        const scanItems = ref([]);
        const knownFolders = ref({});
        const logs = ref([]);

        const appendLog = (type, message) => {
            const time = new Date().toLocaleTimeString();
            logs.value.unshift({ time, type, message });
        };

        const fetchOverview = async () => {
            try {
                const res = await fetch('/api/overview');
                const data = await res.json();
                if (data.c_drive) overview.value.c_drive = data.c_drive;
                if (data.d_drive) overview.value.d_drive = data.d_drive;
                if (data.discovered_items) scanItems.value = data.discovered_items;
                appendLog('info', `全盘状态获取完成: C盘剩余 ${data.c_drive?.free_gb} GB, D盘剩余 ${data.d_drive?.free_gb} GB`);
            } catch (err) {
                appendLog('error', `获取盘符状态失败: ${err.message}`);
            }
        };

        const fetchKnownFolders = async () => {
            try {
                const res = await fetch('/api/known-folders');
                const data = await res.json();
                knownFolders.value = data;
            } catch (err) {
                appendLog('error', `获取已知文件夹失败: ${err.message}`);
            }
        };

        const triggerScan = async () => {
            loading.value = true;
            appendLog('info', '开始全面诊断与扫描...');
            try {
                const res = await fetch('/api/scan', { method: 'POST' });
                const data = await res.json();
                if (data.c_drive) overview.value.c_drive = data.c_drive;
                if (data.d_drive) overview.value.d_drive = data.d_drive;
                if (data.discovered_items) scanItems.value = data.discovered_items;
                appendLog('success', `扫描成功！发现 ${data.discovered_items?.length || 0} 个重点项。`);
            } catch (err) {
                appendLog('error', `扫描失败: ${err.message}`);
            } finally {
                loading.value = false;
            }
        };

        const relocateItem = async (item) => {
            if (!confirm(`确定要将 [${item.name}] 迁移至 D 盘并在原位置建立无缝 Junction 软链接吗？`)) return;
            processingPath.value = item.path;
            appendLog('info', `开始原子迁移: ${item.path}...`);
            try {
                const res = await fetch('/api/relocate', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({
                        source_path: item.path,
                        owning_processes: item.owning_processes || []
                    })
                });
                const result = await res.json();
                if (result.status === 'success') {
                    appendLog('success', `迁移完成: ${item.name} 已成功转为 Junction 链接到 ${result.target_path} (释放 ${result.freed_gb} GB)`);
                    await triggerScan();
                } else {
                    appendLog('error', `迁移未成功: ${result.message}`);
                }
            } catch (err) {
                appendLog('error', `迁移请求异常: ${err.message}`);
            } finally {
                processingPath.value = null;
            }
        };

        const cleanItem = async (item) => {
            if (!confirm(`确定清理缓存目录 [${item.name}] 吗？`)) return;
            processingPath.value = item.path;
            appendLog('info', `正在清理缓存: ${item.path}...`);
            try {
                const res = await fetch('/api/clean', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({
                        target_path: item.path,
                        owning_processes: item.owning_processes || []
                    })
                });
                const result = await res.json();
                if (result.status === 'success') {
                    appendLog('success', `清理完成: ${item.name} 成功清除 ${result.deleted_items} 个文件 (释放 ${result.freed_gb} GB)`);
                    await triggerScan();
                } else {
                    appendLog('error', `清理遇到问题: ${result.message}`);
                }
            } catch (err) {
                appendLog('error', `清理请求异常: ${err.message}`);
            } finally {
                processingPath.value = null;
            }
        };

        const redirectFolder = async (folderName, newPath) => {
            if (!confirm(`确定要将 [${folderName}] 重定向到 [${newPath}] 吗？`)) return;
            appendLog('info', `正在重定向 Known Folder: ${folderName} -> ${newPath}`);
            try {
                const res = await fetch('/api/redirect', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ folder_name: folderName, new_path: newPath })
                });
                const result = await res.json();
                if (result.status === 'success') {
                    appendLog('success', `重定向成功: ${folderName} 已指向 ${newPath}`);
                    await fetchKnownFolders();
                    await triggerScan();
                } else {
                    appendLog('error', `重定向失败: ${result.message}`);
                }
            } catch (err) {
                appendLog('error', `重定向异常: ${err.message}`);
            }
        };

        const batchCleanGreen = async () => {
            const greenItems = scanItems.value.filter(i => i.recommended_action === 'safe_to_delete' && i.size_gb > 0);
            if (greenItems.length === 0) {
                alert('当前没有待清理的安全缓存项。');
                return;
            }
            if (!confirm(`检测到 ${greenItems.length} 个安全缓存项，确定一键清理吗？`)) return;
            for (const item of greenItems) {
                await cleanItem(item);
            }
        };

        const driveBadgeClass = (percent) => {
            if (!percent) return 'bg-slate-800 text-slate-300 border-slate-700';
            if (percent > 85) return 'bg-rose-950/40 text-rose-400 border-rose-800/40';
            if (percent > 70) return 'bg-amber-950/40 text-amber-400 border-amber-800/40';
            return 'bg-emerald-950/40 text-emerald-400 border-emerald-800/40';
        };

        const driveProgressClass = (percent) => {
            if (!percent) return 'bg-cyan-500';
            if (percent > 85) return 'bg-gradient-to-r from-amber-500 to-rose-500';
            if (percent > 70) return 'bg-gradient-to-r from-cyan-500 to-amber-500';
            return 'bg-gradient-to-r from-cyan-500 to-emerald-500';
        };

        const strategyBadgeClass = (strategy) => {
            switch (strategy) {
                case 'safe_to_delete':
                    return 'bg-emerald-950/40 text-emerald-400 border-emerald-800/40';
                case 'relocate_with_junction':
                    return 'bg-cyan-950/40 text-cyan-400 border-cyan-800/40';
                case 'in_app_migration_only':
                    return 'bg-amber-950/40 text-amber-400 border-amber-800/40';
                default:
                    return 'bg-slate-800 text-slate-400 border-slate-700';
            }
        };

        const logTypeClass = (type) => {
            switch (type) {
                case 'success': return 'text-emerald-400 font-bold';
                case 'error': return 'text-rose-400 font-bold';
                case 'info': return 'text-cyan-400';
                default: return 'text-slate-400';
            }
        };

        onMounted(async () => {
            await fetchOverview();
            await fetchKnownFolders();
        });

        return {
            loading,
            processingPath,
            currentTab,
            overview,
            scanItems,
            knownFolders,
            logs,
            triggerScan,
            relocateItem,
            cleanItem,
            redirectFolder,
            batchCleanGreen,
            driveBadgeClass,
            driveProgressClass,
            strategyBadgeClass,
            logTypeClass
        };
    }
}).mount('#app');
