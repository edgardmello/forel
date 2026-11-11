extension Database {
    func migrateV12AddSharedRules() throws {
        try exec(
            """
            ALTER TABLE rules ADD COLUMN shared_rule_id TEXT;
            CREATE UNIQUE INDEX idx_rules_shared_folder
                ON rules(shared_rule_id, folder_id) WHERE shared_rule_id IS NOT NULL;
            """
        )
    }
}
