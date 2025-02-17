import os
from jinja2 import Environment, FileSystemLoader

def generate_policy(template_path, **kargs):

    if not os.path.isfile(template_path):
        raise FileNotFoundError(f"Template file not found: {template_path}")
        exit

    template_dir    = os.path.dirname(template_path)
    template_file   = os.path.split(template_path)[-1]
    jinja_env       = Environment(loader=FileSystemLoader(template_dir))

    if "tags" in kargs and kargs["tags"] not in (None, "", "''", '""'):
        kargs["tags"] = kargs["tags"].strip('"').strip("'").replace(" ","").split(",")
    else:
        kargs["tags"] = []
    try:
        template = jinja_env.get_template(template_file)
    except Exception as e:
        print(f"Error loading template: {e}")

    try:
        rendered_policy = template.render(kargs)
        policy_file_path = os.path.join(template_dir, f'{template_file.split(".")[0]}.yaml')

        with open(policy_file_path, 'w') as output_file:
            output_file.write(rendered_policy)
    except Exception as e:
        print(f"Error rendering template: {e}")