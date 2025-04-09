TEMPLATE = subdirs

ALL_PRO_PATHS = $$files($$_PRO_FILE_PWD_/*.pro, true)
ALL_PRO_PATHS -= $$_PRO_FILE_
CONFIG += release
CONFIG += warn_on
CONFIG += c++latest

defineReplace(get_project_name) {
	abs_pro_dir = $$dirname(1)
	pro_name = $$basename(abs_pro_dir)
	equals(pro_name, "src") {
		abs_pro_dir = $$dirname(abs_pro_dir)
		pro_name = $$basename(abs_pro_dir)
	}
	return ($$pro_name)
}

for(abs_pro_path, ALL_PRO_PATHS) {
	pro_name = $$get_project_name($$abs_pro_path)
	SUBDIRS += $$pro_name
	eval($${pro_name}.file = $$abs_pro_path)
}

# Find dependencies
for(abs_pro_path, ALL_PRO_PATHS) {
	DEPEND_LIBS = $$fromfile($$abs_pro_path, LIBS)
	pro_name = $$get_project_name($$abs_pro_path)
	for(dependency, DEPEND_LIBS) {
		dependency = $$str_member($$dependency, 2, -1)
		contains(SUBDIRS, $$dependency) {
			eval($${pro_name}.depends += $$dependency)
		}
	}
}
